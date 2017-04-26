#!/usr/local/bin/perl
use warnings;
use strict;
$|++;

=head1 NAME

run_pangenome.pl - run the pangenome pipeline

=head1 SYNOPSIS

    USAGE: run_pangenome.pl -P <project code> | --blast_local | --no_blast
                            [-g <genomes.list> ] [-c <clusters.list>] [-w <working directorya>]
                            [--rerun_groups <group_list>] [--expand_only]
                            [--less_strict_panoct]

=head1 OPTIONS

B<--genome_list_file, -g>   :   List of genome names. The order here determines the ordering in later files. [DEFAULT: <working_dir>/genomes.list]

B<--working_dir, -w>        :   Path in which multiple directories are to be created [DEFAULT: current dir]

B<--use_nuc, -n>                :   Use nucleotide versions of blast programs and input files

B<--att_suffix>             :   Provide an alternate extension for recognizing .att files [DEFAULT: ".att"]

B<--project_code>           :   Project code for UGE accounting purposes used when blast jobs/panoct are executed on the grid.

B<--blast_local>            :   Run blast jobs on current host instead of farming them to a grid.

B<--no_blast>               :   Don't rerun blast.

ITERATIVE OPTIONS:

B<--cluster_file, -c>       :   The clustering file determining the order of the steps to run.

B<--rerun_groups>           :   Provide a comma-seperated list of groups to rerun.

B<--expand_only>            :   Sets --no_blast; skips straight to the expansion of
                                'pseudo-genome' names in the very last step's result files. 

PANOCT OPTIONS:

B<--less_strict_panoct> :   Use panoct's "-S N" flag to reduce strictness of clustering

=head1 DESCRIPTION

Run the JCVI Prokaryotic Group's pangenome software, panoct, along with other scripts that perform ancillary functions.

In the absence of a --cluster_file, will run panoct (via run_panoct.pl) on all input genomes found within --genome_list_file.

When used with a --cluster_file, will run the iterative JCVI panoct/pangenome pipeline on the genomes contained within:

1. Read in the cluster file and build an 'itinerary' of steps.

2. For each step: (unless --expand_only is used)

    a. Create a work area for this step.
    b. Create the combined.fasta needed for blast & panoct.
    c. Run NCBI BLAST on the genomes in this step.
    d. Run PanOCT
    e. Create 'pseudo-genome' files.

3. Once all of the steps have been run, replace any instances of 'pseudo-genome' names in certain output files of the final step in the itinerary.  Currently, the following files are modified:

    1. matchtable.txt
    2. centroids.fasta

Modified files are recreated as <filename>.expanded, leaving the originals in place.  The following files are planned to have expansion in later versions of this script:

    1. frameshifts.txt
    2. fragment_fusions.txt

4. A final panoct run is executed after the last step in the itenerary.

=head1 INPUT

The pipeline will run given a variety of setup options.  To run with as few command-line parameters as possible, the pipeline needs to have the following files in the described locations:

B<genomes.list> - Expected in the current working directory.  Can be specified with --genome_list_file.  This file is a single-column file of genome IDs that have been used as filenames.

B<fasta_dir>    - directory within the current working directory containing a multifasta of feature sequences per genome, named according to the IDs in genomes.list

B<att_dir>      - directory within the current working directory containing a 'gene attribute' file per genome, named according to the IDs in genomes.list

B<clusters.list> - Optional.  When present, directs the pipeline to enter 'iterative' mode.  A small sample file might look like:

    L1B1(GenomeA,GenomeB,GenomeC)
    L1B2(GenomeD,GenomeE,GenomeF,GenomeG)
    L1B3(GenomeH,GenomeI,GenomeJ,GenomeK,GenomeL)
    L1B4(GenomeM,GenomeN,GenomeO)
    L2B1(L1B1,L1B2,L1B3l,L1B4)

Using this sample clusters.list file will generate four typical pangenome runs along with one run that uses 'pseudo-genomes' to represent clusters identified in the previous runs.  For this L2 run, the cluster represntatives found in the prior L1 level runs' centroids.fasta files are used as the potential members in newly generated clusters.

Certain useful files from the L2 level run will be 'expanded' such that the cluster reprentatives found in those files are replaced with the entire subset of members from the original cluster, giving the appearance that those expanded files were generated from a single pangenome run including all of the input genomes.

Note that the script 'parse_genbank_files.pl' can be used to generate fasta files and att files from GenBank Flatfiles, which in turn can be retrieved using the script 'ftp_download_ncbi_annotation.pl'

=head1 OUTPUT

The output of panoct is varied and voluminous.  The user is encouraged to seek the file descriptions found in the ./docs directory of the pipeline distribution package.

=head1 CONTACT

    Jason Inman
    jinman@jcvi.org

=cut

use FindBin;
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Cwd qw(cwd abs_path);
use FindBin;
use File::Copy qw(move copy);
use File::Basename;
use File::Path qw(mkpath remove_tree);
use Getopt::Long qw( :config no_auto_abbrev no_ignore_case );
use Pod::Usage;
use grid_tasks;

use Data::Dumper;

my $BIN_DIR = $FindBin::Bin;
my $PANOCT_EXEC      = "$BIN_DIR/panoct.pl";
my $GENE_ORDER_EXEC  = "$BIN_DIR/gene_order.pl";
my $CONVERT_ATT_EXEC = "$BIN_DIR/convert_att_file_to_hsh.pl";
my $STATISTICS_EXEC  = "$BIN_DIR/pangenome_statistics.pl";
my $RUNPANOCT_EXEC   = "$BIN_DIR/run_panoct.pl";

my $DEFAULT_ATT_SUFFIX = 'att';
my $DEFAULT_WORKING_DIR = Cwd::getcwd;

my $genome_list_file    = '';
my $att_suffix          = '.att';
my $working_dir         = '';
my $cluster_file        = '';
my $lfh                 = undef;
my $debug               = 0;

my %opts;
GetOptions( \%opts,
            'att_suffix=s',
            'genome_list_file|g=s',
            'cluster_file|c=s',
            'rerun_groups=s',
            'working_dir|w=s',
            'use_nuc|n',
            'no_blast',
            'blast_local',
            'panoct_local',
            'project_code|P=s',
            'less_strict_panoct',
            'expand_only',
            'help|h',
         ) || die "Problem getting options.\n";                             
pod2usage( { -exitval => 1, -verbose => 2 } ) if $opts{help};

check_options( \%opts );

# Set up logging.
my $log_file = "$working_dir/run_pangenome.log";
open( $lfh, '>', $log_file ) || _die( "Can't open log file $log_file: $!", __LINE__ );

# Run panoct directly on our inputs if there is no cluster file:
unless ( $cluster_file ) {

    _log( "No cluster_file found.  This is ok.\nProceeding with non-iterative pangenome.", 0 );

    # Run single pangenome.  Then exit.
    run_run_panoct( $working_dir );

    exit(0);

} else {

    _log( "Cluster file: $cluster_file\nProceeding with iterative pangenome run.", 0 );

}

# Otherwise, continue with an iterative run:
# Get working_dir variables set up.
my $fasta_dir = "$working_dir/fasta_dir";
my $att_dir = "$working_dir/att_dir";

# Read in the db.list file, get the order of the genomes for later.
my @genome_order = get_genome_order( $genome_list_file );
my %locus2genome;

# read in the cluster file, plot the itinerary, get some files.
my $itinerary = build_itinerary( $cluster_file );

# set up rerun_groups if requested
my @rerun_groups;
if ( $opts{ rerun_groups } ) {

    @rerun_groups = split(',',$opts{rerun_groups});
    _log( "Rerunning groups: " . join( ',', @rerun_groups ) . "\n", 0 );

}

unless ( $opts{ expand_only } ) {

    for my $step ( @$itinerary ) {

        my $step_name = ( keys %$step )[0];

        # Check to see if we are skipping this because it's not in the rerun list:
        if ( $opts{rerun_groups} && no_rerun( \@rerun_groups, $step_name ) )  {

            # and add it to locus2genome if we aren't rerunning.
            _log( "Skipping $step_name", 0 );
            next;

        }

        my $parts = $step->{$step_name};
        _log( "Working on step $step_name\n", 0 );

        # create area to work in.
        my $step_dir = "$working_dir/$step_name";
        unless ( -d $step_dir ) {
            mkdir $step_dir || _die( "Couldn't create $step_dir: $!", __LINE__ );
        }
        chdir $step_dir;
        # create subdirs
        my $step_fasta_dir = "$step_dir/fasta_dir";
        unless ( -d $step_fasta_dir ) {
            mkdir $step_fasta_dir || _die( "Couldn't create $step_fasta_dir: $!", __LINE__ );
        }

        # Get the files we need.
        ## That would be combined.fasta and combined.att
        my $combined_fasta   = make_combined_fasta( $step_fasta_dir, $parts );
        my $combined_att     = make_combined_att( $step_dir, $parts );
        my $genome_list_file = create_genome_list_file( $step_dir, $parts );

        # Call run_panoct.pl
        run_run_panoct( $step_dir, $combined_fasta, $combined_att, $genome_list_file );

        # copy centroid files into the fasta_dir and att_dir
        create_pseudo_genome_files( $step_dir, $step_name );

    }

}

print "Time to expand clusters!\n";

fill_locus2genome( $genome_list_file, \%locus2genome );
expand_clusters( $itinerary );
resolve_frameshift_loci( $itinerary );
my $combined_stuff = run_statistics( );
final_panoct_run( $combined_stuff );

exit(0);


sub no_rerun {
# Used when --rerun_groups has been invoked.
# Return true if the step name is not in the list of groups to rerun.

    my ( $rerun_groups, $step_name ) = @_;

    my $return = 0;

    my %groups = map { $_ => 1 } @{rerun_groups};
    $return++ unless exists( $groups{$step_name} );

    return $return;

}


sub run_statistics {
# Generate final files not already created.
# run statistics on the final results.
# Return final files for post-panoct run.

    # Let's store this all in a tidy little directory
    my $curr_dir = cwd();
    my $stat_dir = "$working_dir/stats";
    mkdir $stat_dir || die "Can't create stats dir: $!\n";
    chdir $stat_dir || die "Can't chdir into stats dir: $!\n";

    # Create the .att file
    my $combined_att = create_final_combined_att( $stat_dir, $genome_list_file );

    # Create .att.dat file
    my $combined_att_dat = create_final_combined_att_dat( $combined_att, $stat_dir );

    # Create .fasta file
    my $combined_fasta = create_final_combined_fasta( $stat_dir, $genome_list_file );

    # Run stats.
    my @cmd = ( $STATISTICS_EXEC, '-a', $combined_att_dat, '-m', "$working_dir/matchtable.txt.expanded",
                '-l', $genome_list_file, '-c', "$working_dir/centroids.fasta.expanded" );
    push( @cmd,( $opts{ use_nuc } ) ? ( '-n', $combined_fasta ) : ( '-s', $combined_fasta ) );

    _log( "Running statistics:\n" . join( ' ', @cmd ) . "\n", 0 );

    system( @cmd ) == 0 || _die( "Failed running statistics!", __LINE__ );

    # check that it worked. TODO Maybe look for a specific file or something.

    my %combined_stuff = (  'att'       => $combined_att,
                            'att_dat'   => $combined_att_dat,
                            'fasta'     => $combined_fasta,
                          );
    return \%combined_stuff;

}


sub final_panoct_run {
# run the final panoct command
# model command line
# panoct.pl -R matchtable.txt.expanded  -f ../../db.txt -g ../combined.att -P ../combined.pep >& panoct.stderr
#    my $cmd = "$PANOCT_EXEC -R matchtable.txt.expanded -f $opts{genome_list} -g combined.att -P combined.fasta";

    my ( $combined_hashref ) = @_;

    my ( $combined_att_file, $combined_fasta ) = @{$combined_hashref}{ qw( att fasta ) };

    # setup for this run.
    my $curr_dir = cwd();
    my $final_dir = "$working_dir/final_panoct_run";
    mkdir $final_dir || die "Couldn't create final panoct directory $final_dir: $!\n";
    chdir $final_dir || die "Couldn't get to final panoct directory $final_dir! $!\n";

    my $expanded_matchtable = 'matchtable.txt.expanded';
    my $tagfile = basename( $genome_list_file );

    # Create symlinks of these files, even though we're going to be lazy and use the originals in the command.
    # This is really for the benefit of people examining the results once the process has finished.
    symlink "../$expanded_matchtable", "./matchtable.txt.expanded"
        || die "Can't create symlink for $expanded_matchtable: $!\n";
    symlink "$combined_att_file", "./combined.att_file"
        || die "Can't create symlink for $combined_att_file: $!\n";
    symlink "$combined_fasta", "./combined.fasta"
        || die "Can't create symlink for $combined_fasta: $!\n";
    symlink "../$tagfile", "./$tagfile"
        || die "Can't create symlink for $tagfile: $!\n";
    symlink '../centroids.fasta.expanded', './centroids.fasta.expanded'
        || die "Can't create symlink for centroids.fasta.expanded: $!\n";
    symlink '../cluster_sizes.txt', './cluster_sizes.txt'
        || die "Can't create symlink for cluster_sizes.txt: $!\n";

    my @cmd = ( $PANOCT_EXEC, '-R', 'matchtable.txt.expanded', '-f', $tagfile, '-g',  'combined.att_file', 
                '-P', 'combined.fasta', '-b', $final_dir, '-c', '0,95' );
    #push( @cmd, '-S', 'N' ) if $opts{less_strict_panoct};
    push( @cmd, '>&', 'final_panoct.log');

    _log( "Running final panoct command in $final_dir:\n" . join( ' ', @cmd ) . "\n", 0 );

    system( @cmd ) == 0 || _die( "Error running final panoct command!", __LINE__ );

    # Now run gene_order.pl one last time
    @cmd = ( $GENE_ORDER_EXEC, '-P', '-W', './cluster_sizes.txt', '-M', './95_core_adjacency_vector.txt',
             '-m', './0_core_adjacency_vector.txt', '-C', './centroids.fasta.expanded', '-t', $tagfile,
             '-A', 'core.att', '-a', 'fGI.att', '-I', 'fGI_report.txt', '>', 'gene_order.txt' );

    _log( "Running gene_order to produce final fGI data:\n" . join ( ' ', @cmd ) . "\n", 0 );

    system( @cmd ) == 0 || _die( "Error running final gene_order command!". __LINE__ ); 

    chdir $curr_dir || die "Can't get to $curr_dir: $!\n";


}


sub create_final_combined_fasta {
# Combine all the fasta files 

    my ( $stat_dir, $genome_list_file ) = @_;

    my $combined_fasta = "$stat_dir/combined.fasta";

    open( my $dfh, '<', $genome_list_file ) || die "2. Can't open $genome_list_file: $!\n";

    open( my $cfh, '>', $combined_fasta ) || die "Can't open $combined_fasta for writing: $!\n";

    while ( <$dfh> ) {

        chomp;
        my $fasta_file = "$fasta_dir/$_.";
        $fasta_file .= ( $opts{ use_nuc } ) ? 'nuc' : 'pep';

        open ( my $afh, '<', $fasta_file ) || die "Can't open fasta_file $fasta_file for reading: $!\n";
        while ( <$afh> ) {
            print $cfh $_;
        }

    }

    return $combined_fasta;

}


sub create_final_combined_att_dat {
# given a path to a att_file, create a .dat from it.

    my ( $att_file, $out_dir ) = @_;

    my $att_dat_file = $att_file . ".dat";

    my @cmd = ( $CONVERT_ATT_EXEC, $att_file, $out_dir );

    _log( "Creating final combined.att.dat file:\n" . join( ' ', @cmd ) . "\n", 0 );

    system( @cmd ) && _die( "Error converting $att_file to $att_dat_file with $CONVERT_ATT_EXEC", __LINE__ );

    return $att_dat_file;

}


sub create_final_combined_att {
# Combine the att files for the final panoct run

    my ( $stat_dir, $genome_list_file ) = @_;

    _log( "Creating final combined.att" , 0 );

    my $combined_att = "$stat_dir/combined" . $att_suffix;

    open( my $dfh, '<', $genome_list_file ) || die "Can't open $genome_list_file: $!\n";

    open( my $cah, '>', $combined_att ) || die "Can't open $combined_att for writing: $!\n";
    while ( <$dfh> ) {

        chomp;
        my $att_file = "$att_dir/$_" . $att_suffix;

        open ( my $afh, '<', $att_file ) || die "Can't open att_file $att_file for reading: $!\n";
        while ( <$afh> ) {
            print $cah $_;
        }

    }

    return $combined_att;

}


sub fill_locus2genome {
# When --expand_only is used, locus2genome isn't populated on the fly, 
# so we have to fill it with data from all of the att files for the
# genomes in --genome_list
# assume everything is in $working_dir/att_dir

    my ( $genome_list, $l2g ) = @_;

    chdir $working_dir || die "Can't get back to working_dir: $! \n";

    open ( my $dlh, '<', $genome_list ) || die "Can't open genome_list: $!\n";

    while ( <$dlh> ) {

        chomp;
        my $current_att_file = "$att_dir/$_" . $att_suffix;
        open ( my $cah, '<', $current_att_file ) || die "Can't open att_file: $current_att_file: $!\n";

        while ( <$cah> ) {

            # add locus to loci/genome hash
            chomp;
            my ( $locus, $genome ) = ( split("\t", $_) )[1,5];
            $l2g->{ $locus } = $genome;

        }

    }    

}


sub get_genome_order {
# turn the list of genome names into an array of genome names,
# the order is determined as they appear in the file.

    my ( $genome_list ) = @_;

    my @genome_list;

    _log( "Getting genome order from $genome_list.", 1 );

    open ( my $dlh, '<', $genome_list ) || die "Couldn't open genome_list file: $!\n";

    while ( <$dlh> ) {

        chomp;
        push @genome_list, $_;

    }

    return @genome_list;

}


sub resolve_frameshift_loci {
# need to create a concatenation of all the frameshift files, with the pseudo-loci
# resolved to the closest non-pseudo-loci centroid representative.

    my ( $itinerary ) = @_;

    my $output_file = abs_path( $cluster_file ) . ".frameshifts";
    open ( my $ofh, '>', $output_file ) || die "Can't open $output_file for writing: $!\n";

    for my $step ( @$itinerary ) {

        my $step_name = ( keys %$step )[0];

        my $frameshift_file = "$working_dir/$step_name/results/frameshifts.txt";
        open( my $ffh, '<', $frameshift_file ) || die "Can't open $frameshift_file for reading: $!\n";
        while ( <$ffh> ) {

            chomp;
            my $line = $_;
            unless ( /^>/ ) {

                $line = resolve_line( $line );

            }

            print $ofh "$line\n";

        }

    }

}


sub resolve_line {
# Helper for the recursive 'resolve locus' sub procedure.
# iterates over each locus in a given line of loci,
# calls 'resolve locus' on each, joins the results and returns the new line.

    my ( $line ) = @_;

    my @loci_in = split( "\t", $line );
    my @loci_out;

    for my $locus ( @loci_in ) {

        push @loci_out, resolve_locus( $locus );

    }

    my $ret_line = join( "\t", @loci_out );
    return $ret_line;

}


sub resolve_locus {
# recursive:
# given a locus name, resolve it if it's a pseudo-locus, otherwise just return what was passed in.

    my ( $locus ) = @_;

    if ( $locus =~ /^(L\d+B\d+)_(\d+)/ ) {

        my ( $branch, $cluster_id ) = ( $1, $2 );
        my $resolved_locus = get_locus_from_centroids( $branch, $cluster_id );
        # Keep calling resolve locus until we get one that's not a pseudo-locus:
        $resolved_locus = resolve_locus( $resolved_locus );

        return $resolved_locus;

    } else {

        return $locus;

    }

}


sub get_locus_from_centroids {
# get the name of the locus representing a particular centroid

    my ( $branch, $cluster_id ) = @_;

    my $locus;
    my $centroids_file = "$working_dir/$branch/results/centroids.fasta";
    my $header = `grep centroid_$cluster_id $centroids_file`;
    if ( $header =~ />centroid_$cluster_id (\S+) / ) {
        $locus = $1;
    } else {
        die "Coudln't get locus for centroid_$cluster_id from $centroids_file\n";
    }

    return $locus;

}


sub expand_element {
# recursive:
# given a locus name, return all of the loci in the associated cluster (if it is a pseudo-loci)
# otherwise, just return what was passed.

    my ( $element, $lookup ) = @_;

    # first make sure we have the handler we need for this one:
    if ( $element =~ /^(L\d+B\d+)_(\d+)/ ) {
        my ( $prefix, $cluster_num ) = ( $1, $2 );
        populate_lookup( $lookup, $prefix ) unless exists ( $lookup->{$prefix} );
        my $row = $lookup->{$prefix}->{$cluster_num};
        $element = join( "\t", map { expand_element( $_, $lookup ) } @$row );
    }

    return $element

}


sub populate_lookup {
# given a refernce to a lookup hash, and a step name (L1B1, L2B3, etc...)
# store the lines of loci names associated with each cluster id

    my ( $lookup, $step_name ) = @_;

    my $matchtable = "$working_dir/$step_name/results/matchtable.txt";
    open ( my $fh, '<', $matchtable ) || die "Can't open $matchtable: $!\n";

    while ( <$fh> ) {

        chomp;

        # Store each line of the matchtable in the lookup.
        my @row = split( /\t/, $_ );
        my $line = shift( @row );

        # remove '-----------' entries (well, three or more '-' in a row, anyway).
        @row = grep { !/[-]{3,}/ } @row;

        $lookup->{$step_name}->{$line} = \@row;

    }

}


sub expand_matchtable {
# replaces the pseudo-loci generated during the iterations with original locus names
# creates a copy of the matchtable file sufixed '.expanded'

    my ( $step_name ) = @_;

    my $orig_matchtable = "$working_dir/$step_name/results/matchtable.txt";
    my $new_matchtable  = "$orig_matchtable.expanded";
    my $cluster_sizes   = "$working_dir/cluster_sizes.txt";

    open( my $nmfh, '>', $new_matchtable ) || die "Can't write to expanded matchtable $new_matchtable: $!\n";
    open( my $csfh, '>', $cluster_sizes  ) || die "Can't write to cluster size file $cluster_sizes: $!\n";

    my %lookup;
    populate_lookup( \%lookup, $step_name );

    # Assume 1 cluster per line aned no skipped numbers between 1 and the last line.
    my $num_lines = `wc -l $orig_matchtable | cut -f 1 -d ' '` || die "Can't get number of lines from $orig_matchtable!\n";

    for ( 1 .. $num_lines ) {

        my $line_num = $_;
        my $orig_name = $step_name . "_$line_num";

        my $row = expand_element( $orig_name, \%lookup );
        print_cluster_size_row( $csfh, $line_num, $row );
        reorder_row( \$row );
        print $nmfh "$line_num$row\n"; # Note: by how the reorder row function works there is a leading tab in $row.

    }

    # copy to working dir
    system("cp $new_matchtable $working_dir") && die "Error copying $new_matchtable to $working_dir: $!\n";
    # This fails to work on occasion.  Sad, it really shouldn't:
    # copy $new_matchtable, $opts{working_dir} || die "Error copying $new_matchtable to $opts{working_dir}: $!\n";

}


sub reorder_row {
# put the values of this row into an array, sort them, and then rejoin them

    my ( $row_ref ) = ( @_);

    my @row = split( "\t", $$row_ref );

    # set up the new row, make it as long as @genome_order, and pre-fill it with \t
    my @new_row = ("\t") x scalar( @genome_order );  

    # put each locus from the original row in the correct location in the new row
    for my $locus ( @row ) {

        # This crazy line... let me explain:
        # 1. $locus2genome{ $locus} returns the name of the genome given the locus.
        # 2. the grep portion: grep { ... } 0..$#genome_order
        #    returns the index within @genome_order for that particular genome
        # 3. we use that index as the index for the new_row into which we store the locus string.
        $new_row[ (grep { $genome_order[ $_ ] eq $locus2genome{ $locus } } 0..$#genome_order)[0] ] = "\t$locus";

    }

    $$row_ref = join('',@new_row);

}


sub print_cluster_size_row {
# Given a row for the matchtable, count the number of entries and print the 
# line for this cluster in cluster_sizes.txt 

    my ( $csfh, $cluster_num, $row ) = @_;

    my $size = scalar(split( "\t", $row));

    print $csfh "$cluster_num\t$size\n";

}


sub expand_centroids_name { 
# helper for the recursive 'expand_centroid' subprocedure.
# opens the input/output
# initial setup for the lookup table, etc.

    my ( $step_name ) = @_;

    my $orig_centroids_fasta = "$working_dir/$step_name/results/centroids.fasta";
    my $new_centroids_fasta  = "$orig_centroids_fasta.expanded";

    open( my $ncfh, '>', $new_centroids_fasta ) || die "Can't write to $new_centroids_fasta: $!\n";
    # Disable buffering for this filehandle...
    select $ncfh;
    $|++;
    my %c_lookup;

    populate_centroid_lookup( \%c_lookup, $step_name );

    open( my $ocfh, '<', $orig_centroids_fasta ) || die "Can't open $orig_centroids_fasta: $!\n";
    while ( <$ocfh> ) {

        chomp;
        my $line = $_;

        if ( $line =~ /^(>centroid_\d+ )([^_ ]+_?\d+)( .*)/ ) {
            my $locus = expand_centroid( $2, \%c_lookup );
            $line = $1 . $locus . $3;
        }

        print $ncfh "$line\n";

    }

    # ... or this copy to working dir gets truncated sometimes.  (I've seen it happen!!)
    copy $new_centroids_fasta, $working_dir; 

    select STDOUT;

}


sub expand_centroid {
# recursive:
# if centroid needs to be expanded, expand it, otherwise, simply return what we were given

    my ( $centroid, $c_lookup ) = @_;

    if ( $centroid =~ /^(L\d+B\d+)_(\d+)/ ) {
        my ( $prefix, $cluster_num ) = ( $1, $2 );
        populate_centroid_lookup( $c_lookup, $prefix ) unless exists ( $c_lookup->{ $prefix } );
        $centroid = expand_centroid( $c_lookup->{ $prefix }->{ $cluster_num }, $c_lookup );
    }

    return $centroid;

}


sub populate_centroid_lookup {
# store the cluster->loci lookups for each fasta in a centroids file

    my ( $lookup, $step_name ) = @_;

    my $centroid_file = "$working_dir/$step_name/results/centroids.fasta";
    open( my $fh, '<', $centroid_file ) || die "Can't open $centroid_file: $!";

    while ( <$fh> ) {
        if ( /^>centroid_(\d+) ([^_ ]+_?[^ ]+) / ) {
            $lookup->{ $step_name }->{ $1 } = $2;
        } else {
            next;
        }
    }

}


sub expand_frameshifts { 

    my ( $step_name ) = @_;

}


sub expand_fragment_fusions {

    my ( $step_name ) = @_;

}


sub expand_clusters {
# Need to 'expand' psuedo-names in matchtable.txt, cat the frameshift files, and perhaps the fragment_fusions.
# Maybe the paralogs file.

    my ( $itinerary ) = @_;

    my $last_step = \%{ $itinerary->[ -1 ] };
    my $last_step_name = ( keys %$last_step )[0];

    expand_centroids_name( $last_step_name );
    expand_matchtable( $last_step_name );
    expand_frameshifts( $last_step_name );      # Not yet implemented.
    expand_fragment_fusions( $last_step_name ); # Not yet implemented.

}


sub create_pseudo_genome_files {
# create files representing a step that can be used as input for a downstream step in the pipeline.

    my ( $step_dir, $step_name ) = @_;

    my $step_results = "$step_dir/results";

    my $num_clusters = 0;

    my $fasta_file = "$fasta_dir/$step_name.";
    $fasta_file .= ( $opts{ use_nuc } ) ? 'nuc' : 'pep';

    my @cmd = ( $GENE_ORDER_EXEC, '-W', "$step_results/cluster_weights.txt", '-M', "$step_results/0_core_adjacency_vector.txt",
                '-C', "$step_results/centroids.fasta", '-A', "$att_dir/$step_name" . $att_suffix, '-g', $fasta_file, '-l', '5',
                '-p', $step_name );
    push( @cmd, '-P' ) unless ( $opts{ use_nuc } );

    _log( "Creating pseudo-genome file for $step_name:\n" . join( ' ', @cmd ) . "\n", 0 );
              
    system( @cmd ) == 0 ||  _die( "Error running gene_order.pl command!", __LINE__ );
    _die( "Didn't create att_file $att_dir/$step_name" . "$att_suffix from gene_order.pl command!", __LINE__ )  unless ( -f "$att_dir/$step_name" . $att_suffix );

}


sub run_run_panoct {

    my ( $step_dir, $combined_fasta, $combined_att, $genome_list ) =@_;

    my @cmd = ( $RUNPANOCT_EXEC, '-w', $step_dir, '-P', $opts{ project_code } );
    push( @cmd, '-g', $genome_list ) if $genome_list;
    push( @cmd, '-a', $combined_att ) if $combined_att;
    push( @cmd, '-f', $combined_fasta ) if $combined_fasta;
    push( @cmd, '--use_nuc' ) if ( $opts{ use_nuc } );
    push( @cmd, '--strict', 'low' ) if ( $opts{ less_strict_panoct } );
    push( @cmd, '--panoct_local' ) if ( $opts{ panoct_local } );
    if ( $opts{ no_blast } ) {
        my $blast_file = "$step_dir/combined.blast";
        if ( -f $blast_file ) {
            push( @cmd, '--blast_file', $blast_file );
        } else {
            _die( "--no_blast used, but I can't find combined.blast in $step_dir!", __LINE__ );
        }
    }

# hack: REMOVE ONCE NEW_PLOT_PANGENOME is FIXED
push( @cmd, '--no_new_plot' );

    _log( "Running run_panoct.pl:\n" . join( ' ', @cmd ), 0 );

    system( @cmd ) == 0 || _die( "Problem with running run_panoct.pl", __LINE__ );

}


sub create_genome_list_file {
# create the genome_list_file for a particular step 

    my ( $step_dir, $parts ) = @_;

    my $genome_list_file = "$step_dir/genomes.list";

    _log( "Creating genome_list_file: $genome_list_file", 0 );

    open( my $dlfh, '>', $genome_list_file ) || die "Can't open $genome_list_file: $!";

    for my $part ( @$parts ) {

        print $dlfh "$part\n";

    }

    return( $genome_list_file );

}


sub make_combined_fasta {
# creates the combined.fasta used by panoct from a particular step's genomes

    my ( $step_fasta_dir, $parts ) = @_;

    my $combined_fasta = "$step_fasta_dir/combined.fasta";

    _log( "Creating $combined_fasta.", 0 );

    open( my $cfh, '>', $combined_fasta ) || die "Can't write to $combined_fasta: $!\n";

    for my $part ( @$parts ) {

        my $fasta_file = "$fasta_dir/$part.";
        $fasta_file .= ( $opts{ use_nuc } ) ? 'nuc' : 'pep';
        open( my $ffh, '<', $fasta_file ) || die "Can't open $fasta_file: $!";
        while (<$ffh>) {
            print $cfh $_;
        }

    }

    return( $combined_fasta );

}


sub make_combined_att {
# creates the combined.att used by panoct from a particular step's genomes

    my ( $step_dir, $parts ) = @_;

    my $combined_att = "$step_dir/combined" . $att_suffix;

    _log( "Making $combined_att", 0 );

    open( my $cah, '>', $combined_att ) || die "Can't write to $combined_att: $!\n";

    for my $part ( @$parts ) {

        my $att_file = "$att_dir/$part" . $att_suffix;
        open( my $afh, '<', $att_file ) || die "Can't open $att_file: $!";
        while (<$afh>) {

            # print line to combined.att
            print $cah $_;
            
        }

    }

    return( $combined_att );

}
    

sub build_itinerary {
# Seperate the cluster file into steps, retrieve all fasta & gene_att files at this time, too.

    my ( $cluster_file ) = @_;
    my @itinerary;

    _log( "Building itinerary from cluster file: $cluster_file.", 1 );

    open( my $ifh, '<', $cluster_file ) || die "Can't open cluster_file $cluster_file: $!\n";

    while ( <$ifh> ) {

        chomp;

        my $step = get_step( $_ );
        push @itinerary, $step;

        check_files( $step );

    }

    return \@itinerary

}


sub check_files {
# verify that the fasta file and att file exist for each part of a given step.

    my ( $step ) = @_;
    my @missing_fasta;
    my @missing_att;

    my $step_name = (keys %$step)[0];
    for my $part ( @{$step->{ $step_name }} ) {

        # skip these for now.  They'll be here later.
        next if ( $part =~ /^L\d+B\d+$/ );

        my $fasta_file = "$fasta_dir/$part.";
        $fasta_file .= ( $opts{ use_nuc } ) ? 'nuc' : 'pep';
            
        unless ( -f "$fasta_file" ) {
            push @missing_fasta, $part;
        }
        unless ( -f "$att_dir/$part" . $att_suffix ) {
            push @missing_att, $part;
        }

    }

    my $errors;
    if ( scalar @missing_fasta ) {
        $errors .= "Missing the following fasta from step $step_name: " . join( ',', @missing_fasta ) . "\n";
    }
    if ( scalar @missing_att ) {
        $errors .= "Missing the following atts from step $step_name: " . join( ',', @missing_att ) . "\n";
    }

}


sub get_step {
# return a hash describing the parts (genomes) given a line representing that step.

    my ( $line ) = @_;
    my %step;

    if ( $line =~ /^(L\d+B\d+)\((.*)\)/ ) {

        # Build @parts list.
        my $step_id = $1;
        my @parts = split( ',' , $2 ); 
        @parts = map { (fileparse( $_, qr/\.[^.]*/))[0] } @parts;
        $step{$step_id} = \@parts;

    } else {

        die "Don't know what to do with this line: $line\n";

    }

    return \%step;

}


sub check_options {
# some validations up-front based on supplied parameters

    my ( $opts ) = @_;
    my $errors;

    $working_dir = $opts{ working_dir } // $DEFAULT_WORKING_DIR;
    $errors .= "Can't find working directory $working_dir\n" unless ( -d $working_dir );
    $att_suffix = $opts{ att_suffix } // $att_suffix;

    # check genome list
    $genome_list_file = $opts{ genome_list_file } // "$working_dir/genomes.list";
    $errors .= "Can't find genome_list_file: $genome_list_file\n" unless ( -f $genome_list_file );

    # check cluster file
    if ( $opts{ cluster_file } ) { 

        $cluster_file = $opts{ cluster_file };
        $errors .= "Can't find cluster_file: $cluster_file\n" unless ( -f $cluster_file );

    } elsif ( -f "$working_dir/clusters.list" ) {

        $cluster_file = "$working_dir/clusters.list";

    }

    die "$errors" if $errors;

}

sub _log {

    my ( $msg, $lvl ) = ( @_ );

    chomp( $msg );
    print $lfh "\n$msg\n" if ( $lvl <= $debug );

}


sub _die {

    my ( $msg, $line ) = @_;

    _log( $msg, 0 );
    die "$msg at line $line\n";

}