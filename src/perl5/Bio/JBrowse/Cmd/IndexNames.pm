package Bio::JBrowse::Cmd::IndexNames;

=head1 NAME

Bio::JBrowse::Cmd::IndexNames - script module to create or update a
JBrowse names index from source files.  Main script POD is in generate-names.pl.

=cut

use strict;
use warnings;

use base 'Bio::JBrowse::Cmd';

use File::Spec ();
use POSIX ();
use DB_File ();
use Storable ();
use File::Path ();
use File::Temp ();
use List::Util ();

use GenomeDB ();
use Bio::JBrowse::HashStore ();

sub option_defaults {(
    dir => 'data',
    completionLimit => 20,
    locationLimit => 100,
    mem => 256 * 2**20,
    tracks => [],
)}

sub option_definitions {(
"dir|out=s",
"completionLimit=i",
"locationLimit=i",
"verbose|v+",
"noSort",
"thresh=i",
"sortMem=i",
"mem=i",
"workdir=s",
'tracks=s@',
'hashBits=i',
'incremental|i',
"help|h|?",
'safeMode',
'compress'
)}

sub initialize {
    my ( $self ) = @_;

    # these are used in perf-critical tight loops, make them accessible faster
    $self->{max_completions} = $self->opt('completionLimit');
    $self->{max_locations} = $self->opt('locationLimit');

    $self->{stats} = {
        total_namerec_bytes => 0,
        namerecs_buffered   => 0,
        tracksWithNames => [],
        record_stream_estimated_count => 0,
        operation_stream_estimated_count => 0,
    };
}

sub run {
    my ( $self ) = @_;

    my $outDir = $self->opt('dir');
    -d $outDir or die "Output directory '$outDir' does not exist.\n";
    -w $outDir or die "Output directory '$outDir' is not writable.\n";

    my $gdb = GenomeDB->new( $outDir );

    my $refSeqs = $gdb->refSeqs;
    unless( @$refSeqs ) {
        die "No reference sequences defined in configuration, nothing to do.\n";
    }
    my @tracks = grep $self->track_is_included( $_->{label} ),
                      @{ $gdb->trackList || [] };
    unless( @tracks ) {
        die "No tracks. Nothing to do.\n";
    }

    $self->vprint( "Tracks:\n".join('', map "    $_->{label}\n", @tracks ) );

    # find the names files we will be working with
    my $names_files = $self->find_names_files( \@tracks, $refSeqs );
    unless( @$names_files ) {
        warn "WARNING: No feature names found for indexing,"
             ." only reference sequence names will be indexed.\n";
    }

    $self->load( $refSeqs, $names_files );

    # store the list of tracks that have names
    $self->name_store->meta->{track_names} = [
        $self->_uniq(
            @{$self->name_store->meta->{track_names}||[]},
            @{$self->{stats}{tracksWithNames}}
            )
    ];

    # record the fact that all the keys are lowercased
    $self->name_store->meta->{lowercase_keys} = 1;

    # set up the name store in the trackList.json
    $gdb->modifyTrackList( sub {
                               my ( $data ) = @_;
                               $data->{names}{type} = 'Hash';
                               $data->{names}{url}  = 'names/';
                               return $data;
                           });

    return;
}

sub load {
    my ( $self, $ref_seqs, $names_files ) = @_;

    # convert the stream of name records into a stream of operations to do
    # on the data in the hash store
    my $operation_stream = $self->make_operation_stream(
        $self->make_name_record_stream( $ref_seqs, $names_files ),
        $names_files
    );

    $self->name_store->empty unless $self->opt('incremental');

    $self->vprint( "Using ".$self->hash_bits."-bit hashing\n" );

    # make a stream of key/value pairs and load them into the HashStore
    $self->name_store->stream_set(
        $self->make_key_value_stream( $operation_stream ),
        $self->{stats}{key_count},
        ( $self->opt('incremental')
              ? sub {
                  return $self->_mergeIndexEntries( @_ );
                }
              : ()
        )
    );
}

sub _uniq {
    my $self = shift;
    my %seen;
    return grep !($seen{$_}++), @_;
}

sub _mergeIndexEntries {
    my ( $self, $a, $b ) = @_;

    # merge exact
    {
        my $aExact = $a->{exact} ||= [];
        my $bExact = $b->{exact} || [];
        no warnings 'uninitialized';
        my %exacts = map { join( '|', @$_ ) => 1 } @$aExact;
        while ( @$bExact &&  @$aExact < $self->{max_locations} ) {
            my $e = shift @$bExact;
            if( ! $exacts{ join('|',@$e) }++ ) {
                push @{$aExact}, $e;
            }
        }
    }

    # merge prefixes
    {
        my $aPrefix = $a->{prefix} ||= [];
        # only merge if the target prefix is not already full
        if( ref $aPrefix->[-1] ne 'HASH' ) {
            my $bPrefix = $b->{prefix} || [];
            my %prefixes = map { $_ => 1 } @$aPrefix; #< keep the prefixes unique
            while ( @$bPrefix && @$aPrefix < $self->{max_completions} ) {
                my $p = shift @$bPrefix;
                if ( ! $prefixes{ $p }++ ) {
                    push @{$aPrefix}, $p;
                }
            }
        }
    }

    return $a;
}

sub make_file_record {
    my ( $self, $track, $file ) = @_;
    -f $file or die "$file not found\n";
    -r $file or die "$file not readable\n";
    my $gzipped = $file =~ /\.(txt|json|g)z$/;
    my $type = $file =~ /\.txtz?$/      ? 'txt'  :
               $file =~ /\.jsonz?$/     ? 'json' :
               $file =~ /\.vcf(\.gz)?$/ ? 'vcf'  :
                                           undef;

    if( $type ) {
        return { gzipped => $gzipped, fullpath => $file, type => $type, trackName => $track->{label} };
    }
    return;
}

sub track_is_included {
    my ( $self, $trackname ) = @_;
    my $included = $self->{included_track_names} ||= do {
        my @tracks = @{ $self->opt('tracks') };
        my $inc = { map { $_ => 1 } map { split ',', $_ } @tracks };
        @tracks ? sub { $inc->{ shift() } } : sub { 1 };
    };
    return $included->( $trackname );
}

sub name_store {
    my ( $self ) = @_;
    return $self->{name_store} ||= Bio::JBrowse::HashStore->open(
        dir   => File::Spec->catdir( $self->opt('dir'), "names" ),
        work_dir => $self->opt('workdir'),
        mem => $self->opt('mem'),
        compress => $self->opt('compress'),

        hash_bits => $self->hash_bits,

        verbose => $self->opt('verbose')
    );
}
sub close_name_store {
    delete shift->{name_store};
}

sub hash_bits {
    my $self = shift;
    # set the hash size to try to get about 5-10KB per file, at an
    # average of about 500 bytes per name record, for about 10 records
    # per file (uncompressed). if the store has existing data in it,
    # this will be ignored.
    return $self->{hash_bits} ||= $self->opt('hashBits')
      || do {
          if( $self->{stats}{record_stream_estimated_count} ) {
              my $records_per_bucket = $self->opt('compress') ? 40 : 10;
              my $bits = 4*int( log( $self->{stats}{record_stream_estimated_count} / $records_per_bucket )/ 4 / log(2));
              # clamp bits between 4 and 32
              sprintf( '%0.0f', List::Util::max( 4, List::Util::min( 32, $bits ) ));
          }
          else {
              12
          }
      };
}

sub make_name_record_stream {
    my ( $self, $refseqs, $names_files ) = @_;
    my @names_files = @$names_files;

    my $name_records_iterator = sub {};
    my @namerecord_buffer;

    # insert a name record for all of the reference sequences
    for my $ref ( @$refseqs ) {
        $self->{stats}{name_input_records}++;
        $self->{stats}{namerecs_buffered}++;
        my $rec = [ @{$ref}{ qw/ name length name seqDir start end seqChunkSize/ }];
        $self->{stats}{total_namerec_bytes} += length join(",",$rec);
        push @namerecord_buffer, $rec;
    }

    my %trackHash;

    my $trackNum = 0;

    return sub {
        while( ! @namerecord_buffer ) {
            my $nameinfo = $name_records_iterator->() || do {
                my $file = shift @names_files;
                return unless $file;
                $name_records_iterator = $self->make_names_iterator( $file );
                $name_records_iterator->();
            } or return;
            my @aliases = map { ref($_) ? @$_ : $_ }  @{$nameinfo->[0]};
            foreach my $alias ( @aliases ) {
                    my $track = $nameinfo->[1];
                    unless ( defined $trackHash{$track} ) {
                        $trackHash{$track} = $trackNum++;
                        push @{$self->{stats}{tracksWithNames}}, $track;
                    }
                    $self->{stats}{namerecs_buffered}++;
                    push @namerecord_buffer, [
                        $alias,
                        $trackHash{$track},
                        @{$nameinfo}[2..$#{$nameinfo}]
                        ];
            }
        }
        return shift @namerecord_buffer;
    };
}

sub make_key_value_stream {
    my $self    = shift;
    my $workdir = $self->opt('workdir') || $self->opt('dir');

    my $tempfile = File::Temp->new( TEMPLATE => 'names-build-tmp-XXXXXXXX', DIR => $workdir, UNLINK => 1 );
    $self->vprint( "Temporary key-value DBM file: $tempfile\n" );

    # load a temporary DB_File with the completion data
    $self->_build_index_temp( shift, $tempfile ); #< use shift to free the $operation_stream after index is built

    # reopen the temp store with default cache size to save memory
    my $temp_store = $self->name_store->db_open( $tempfile, &POSIX::O_RDONLY, 0666 );
    $self->{stats}{key_count} = scalar keys %$temp_store;
    return sub {
        my ( $k, $v ) = each %$temp_store;
        return $k ? ( $k, Storable::thaw($v) ) : ();
    };
}

sub _build_index_temp {
    my ( $self, $operation_stream, $tempfile ) = @_;

    my $temp_store = $self->name_store->db_open(
        $tempfile, &POSIX::O_RDWR|&POSIX::O_TRUNC, 0666,
        { flags => 0x1, cachesize => $self->opt('mem') }
        );

    my $progressbar;
    my $progress_next_update = 0;
    if ( $self->opt('verbose') ) {
        print "Estimating $self->{stats}{operation_stream_estimated_count} index operations on $self->{stats}{record_stream_estimated_count} completion records\n";
        eval {
            require Term::ProgressBar;
            $progressbar = Term::ProgressBar->new({name  => 'Gathering locations, generating completions',
                                                   count => $self->{stats}{operation_stream_estimated_count},
                                                   ETA   => 'linear', });
            $progressbar->max_update_rate(1);
        }
    }

    # now write it to the temp store
    while ( my $op = $operation_stream->() ) {
        $self->do_hash_operation( $temp_store, $op );
        $self->{stats}{operations_processed}++;

        if ( $progressbar && $self->{stats}{operations_processed} > $progress_next_update
             && $self->{stats}{operations_processed} < $self->{stats}{operation_stream_estimated_count}
           ) {
            $progress_next_update = $progressbar->update( $self->{stats}{operations_processed} );
        }
    }

    if ( $progressbar && $self->{stats}{operation_stream_estimated_count} >= $progress_next_update ) {
        $progressbar->update( $self->{stats}{operation_stream_estimated_count} );
    }
}


sub find_names_files {
    my ( $self, $tracks, $refseqs ) = @_;

    my @files;
    for my $track (@$tracks) {
        for my $ref (@$refseqs) {
            my $dir = File::Spec->catdir(
                $self->opt('dir'),
                "tracks",
                $track->{label},
                $ref->{name}
                );

            # read either names.txt or names.json files
            my $name_records_iterator;
            my $names_txt  = File::Spec->catfile( $dir, 'names.txt'  );
            if( -f $names_txt ) {
                push @files, $self->make_file_record( $track, $names_txt );
            }
            else {
                my $names_json = File::Spec->catfile( $dir, 'names.json' );
                if( -f $names_json ) {
                    push @files, $self->make_file_record( $track, $names_json );
                }
            }
        }

        # try to detect VCF tracks and index their VCF files
        if( $track->{storeClass}
            && ( $track->{urlTemplate} && $track->{urlTemplate} =~ /\.vcf\.gz/
             || $track->{storeClass} =~ /VCFTabix$/ )
            ) {
            my $path = File::Spec->catfile( $self->opt('dir'), $track->{urlTemplate} );
            if( -f $path ) {
                push @files, $self->make_file_record( $track, $path );
            }
        }

    }

    return \@files;
}

sub make_operation_stream {
    my ( $self, $record_stream, $names_files ) = @_;

    $self->{stats}{namerecs_converted_to_operations} = 0;
    my @operation_buffer;
    # try to fill the operation buffer a bit to estimate the number of operations per name record
    {
        while( @operation_buffer < 50000 && ( my $name_record = $record_stream->()) ) {
            $self->{stats}{namerecs_converted_to_operations}++;
            push @operation_buffer, $self->make_operations( $name_record );
        }
    }

    # estimate the total number of name records we probably have based on the input file sizes
    #print "sizes: $self->{stats}{total_namerec_bytes}, buffered: $namerecs_buffered, b/rec: ".$total_namerec_sizes/$namerecs_buffered."\n";
    $self->{stats}{avg_record_text_bytes} = $self->{stats}{total_namerec_bytes}/($self->{stats}{namerecs_buffered}||1);
    $self->{stats}{total_input_bytes} = List::Util::sum( map { -s $_->{fullpath} } @$names_files ) || 0;
    $self->{stats}{record_stream_estimated_count} = int( $self->{stats}{total_input_bytes} / ($self->{stats}{avg_record_text_bytes}||1));;
    $self->{stats}{operation_stream_estimated_count} = $self->{stats}{record_stream_estimated_count} * int( @operation_buffer / ($self->{stats}{namerecs_converted_to_operations}||1) );

    if( $self->opt('verbose') ) {
        print "Sampled input stats:\n";
        while( my ($k,$v) = each %{$self->{stats}} ) {
            $k =~ s/_/ /g;
            printf( '%40s'." $v\n", $k );
        }
    }

    return sub {
        unless( @operation_buffer ) {
            if( my $name_record = $record_stream->() ) {
                #$self->{stats}{namerecs_converted_to_operations}++;
                push @operation_buffer, $self->make_operations( $name_record );
            }
        }
        return shift @operation_buffer;
    };
}

my $OP_ADD_EXACT  = 1;
my $OP_ADD_PREFIX = 2;

sub make_operations {
    my ( $self, $record ) = @_;

    my $lc_name = lc $record->[0];
    unless( $lc_name ) {
        warn "WARNING: some blank name records found, skipping.\n"
           unless $self->{already_warned_about_blank_name_records}++;
        return;
    }

    my @ops = ( [ $lc_name, $OP_ADD_EXACT, $record ] );

    if( $self->{max_completions} > 0 ) {
        # generate all the prefixes
        my $l = $lc_name;
        chop $l;
        while ( $l ) {
            push @ops, [ $l, $OP_ADD_PREFIX, $record->[0] ];
            chop $l;
        }
    }

    $self->{stats}{operations_made} += scalar @ops;

    return @ops;
}

my %full_entries;
sub do_hash_operation {
    my ( $self, $store, $op ) = @_;

    my ( $lc_name, $op_name, $record ) = @$op;

    if( $op_name == $OP_ADD_EXACT ) {
        my $r = $store->{$lc_name};
        $r = $r ? $self->_hash_operation_thaw($r) : { exact => [], prefix => [] };

        my $exact = $r->{exact};
        if( @$exact < $self->{max_locations} ) {
            # don't insert duplicate locations
            no warnings 'uninitialized';
            if( ! grep {
                      $record->[1] == $_->[1] && $record->[3] eq $_->[3] && $record->[4] == $_->[4] && $record->[5] == $_->[5] 
                  } @$exact
              ) {
                push @$exact, $record;
                $store->{$lc_name} = $self->_hash_operation_freeze( $r );
            }
        }
        # elsif( $verbose ) {
        #     print STDERR "Warning: $name has more than --locationLimit ($self->{max_locations}) distinct locations, not all of them will be indexed.\n";
        # }
    }
    elsif( $op_name == $OP_ADD_PREFIX && ! exists $full_entries{$lc_name} ) {
        my $r = $store->{$lc_name};
        $r = $r ? $self->_hash_operation_thaw($r) : { exact => [], prefix => [] };

        my $name = $record;

        my $p = $r->{prefix};
        if( @$p < $self->{max_completions} ) {
            if( ! grep $name eq $_, @$p ) { #< don't insert duplicate prefixes
                push @$p, $name;
                $store->{$lc_name} = $self->_hash_operation_freeze( $r );
            }
        }
        elsif( @$p == $self->{max_completions} ) {
            push @$p, { name => 'too many matches', hitLimit => 1 };
            $store->{$lc_name} = $self->_hash_operation_freeze( $r );
            $full_entries{$lc_name} = 1;
        }
    }
}

sub _hash_operation_freeze {  Storable::freeze( $_[1] ) }
sub _hash_operation_thaw   {    Storable::thaw( $_[1] ) }



# each of these takes an input filename and returns a subroutine that
# returns name records until there are no more, for either names.txt
# files or old-style names.json files
sub make_names_iterator {
    my ( $self, $file_record ) = @_;
    if( $file_record->{type} eq 'txt' ) {
        my $input_fh = $self->open_names_file( $file_record );
        # read the input json partly with low-level parsing so that we
        # can parse incrementally from the filehandle.  names list
        # files can be very big.
        return sub {
            my $t = <$input_fh>;
            if( $t ) {
                $self->{stats}{name_input_records}++;
                $self->{stats}{total_namerec_bytes} += length $t;
                return eval { JSON::from_json( $t ) };
            }
            return undef;
        };
    }
    elsif( $file_record->{type} eq 'json' ) {
        # read old-style names.json files all from memory
        my $input_fh = $self->open_names_file( $file_record );

        my $data = JSON::from_json(do {
            local $/;
            my $text = scalar <$input_fh>;
            $self->{stats}{total_namerec_bytes} += length $text;
            $text;
        });

        $self->{stats}{name_input_records} += scalar @$data;

        return sub { shift @$data };
    }
    elsif( $file_record->{type} eq 'vcf' ) {
        my $input_fh = $self->open_names_file( $file_record );
        no warnings 'uninitialized';
        return sub {
            my $line;
            while( ($line = <$input_fh>) =~ /^#/ ) {}
            return unless $line;

            $self->{stats}{name_input_records}++;
            $self->{stats}{total_namerec_bytes} += length $line;

            my ( $ref, $start, $name, $basevar ) = split "\t", $line, 5;
            $start--;
            return [[$name],$file_record->{trackName},$name,$ref, $start, $start+length($basevar)];
        };
    }
    else {
        warn "ignoring names file $file_record->{fullpath}.  unknown type $file_record->{type}.\n";
        return sub {};
    }
}

sub open_names_file {
    my ( $self, $filerec ) = @_;
    my $infile = $filerec->{fullpath};
    if( $filerec->{gzipped} ) {
        # can't use PerlIO::gzip, it truncates bgzipped files
        my $z;
        eval {
            require IO::Uncompress::Gunzip;
            $z = IO::Uncompress::Gunzip->new( $filerec->{fullpath }, -MultiStream => 1 )
                or die "IO::Uncompress::Gunzip failed: $IO::Uncompress::Gunzip::GunzipError\n";
        };
        if( $@ ) {
            # fall back to use gzip command if available
            if( `which gunzip` ) {
                open my $fh, '-|', 'gzip', '-dc', $filerec->{fullpath}
                   or die "$! running gunzip";
                return $fh;
            } else {
                die "cannot uncompress $filerec->{fullpath}, could not use either IO::Uncompress::Gunzip nor gzip";
            }
        }
        else {
            return $z;
        }
    }
    else {
        open my $fh, '<', $infile or die "$! reading $infile";
        return $fh;
    }
}


1;
