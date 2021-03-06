#!/usr/bin/env perl

###############################################################################
#                                                                             #
#       Copyright (C) 2016-2017 J. Craig Venter Institute (JCVI).             #
#       All rights reserved.                                                  #
#                                                                             #
###############################################################################
#                                                                             #
#    This program is free software: you can redistribute it and/or modify     #
#    it under the terms of the GNU General Public License as published by     #
#    the Free Software Foundation, either version 3 of the License, or        #
#    (at your option) any later version.                                      #
#                                                                             #
#    This program is distributed in the hope that it will be useful,          #
#    but WITHOUT ANY WARRANTY; without even the implied warranty of           #
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            #
#    GNU General Public License for more details.                             #
#                                                                             #
#    You should have received a copy of the GNU General Public License        #
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.    #
#                                                                             #
###############################################################################
###############################################################################

use warnings;
use strict;
$|++;

=head1 NAME

create_mev_table.pl - Formats Panocts matchtable results into a .mev format

=head1 SYNOPSIS

  USAGE: create_mev_table.pl --matchtable
         --genomes_list
         --att_file
         --output [Optional]
         --help [Optional]

=head1 OPTIONS

B<--matchtable|m>   : Matchtable file created by PanOct

B<--genomes_list|g> : List of genomes

B<--att_file|a>     : Genome attribute file

B<--output|o>       : Output directory

B<--help|h>         : Prints help

=head1 OUTPUT

mev.table - New .mev file representing PanOct's matchtable results

=cut
    
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
use Pod::Usage;
use Cwd;
use File::Basename;
use File::Slurp;
use File::Path;
use Data::Dumper;

my %opts;

GetOptions( \%opts, 
	    'matchtable|m=s',
	    'genomes_list|g=s',
	    'att_file|a=s',
	    'output|o=s',
	    'help|h') || die "Error getting options! $!";

pod2usage( { -exitval => 1, -verbose => 2 } ) if $opts{help};

my $OUTPUT_DIR;
                    
&check_params;

my $dbs = parse_dbs($opts{genomes_list});
my $matchtable_hsh = parse_matchtable($opts{matchtable});
my $att_file_hsh = parse_att_file($opts{att_file});

&join_files($dbs,$matchtable_hsh,$att_file_hsh);

sub join_files{
    my ($dbs,$matchtable,$att_file) = @_;

    open(my $fh, ">", "$OUTPUT_DIR/mev.table");
    select $fh;

    my @headers = ("assembly",
		   "locus",
		   "end5",
		   "end3",
		   "protein name",
		   "genome",
		   "protein length",
		   "TIGRFAM Role ID",
		   "HMMs");

    map{print "$_\t"} @headers;

    print "cluster_id\t";

    foreach my $db(sort {$a<=>$b} keys %$dbs){
	print $dbs->{$db} . "\t";
    }

    print "\n";

    foreach my $cluster(sort {$a<=>$b} keys %$matchtable){

	my $att_file_locus = $matchtable->{$cluster}->{first};
	my $att_file_line = $att_file->{$att_file_locus};

	my @att_values = split(/\t/,$att_file_line);
	my $asmbl_id = $att_values[5] . "." . $att_values[0];

	$att_values[0] = $asmbl_id;

	for(my $i = 0; $i < scalar @headers; $i++){
	    if($att_values[$i]){
		print "$att_values[$i]\t";
	    }else{
		print "\t";
	    }
	}

	print "$cluster\t";

	foreach my $position(sort {$a<=>$b} keys %{$matchtable->{$cluster}->{members}}){
	    if($matchtable->{$cluster}->{members}->{$position} ne '----------'){
		print "1" . "\t";
	    }else{
		print "0" . "\t";
	    }
	}

	print "\n";
    }
    
    close $fh;
}
sub parse_att_file{
    my $file = shift;

    open(my $fh, "<", $file);

    my $hsh;

    while(<$fh>){
	my $line = $_;
	$line =~ s/\s+$//;

	my @values = split(/\t/,$line);
	$hsh->{$values[1]} = $line;
    }

    return $hsh;
}
sub parse_matchtable{
    my $file = shift;
    open(my $fh, "<", $file);
    
    my $hsh;

    while(<$fh>){
	my $line = $_;
	$line =~ s/\s+$//;
	my @values = split(/\t/,$line);
	my $id = shift(@values);

	for(my $i = 0; $i < scalar @values; $i++){
	    my $locus = $values[$i];
	    $locus =~ s/\s+$//;

	    $hsh->{$id}->{members}->{$i} = $locus;

	    unless($locus eq '----------'){
		unless(exists $hsh->{$id}->{first}){
		    $hsh->{$id}->{first} = $locus;
		}
	    }
	}
    }

    return $hsh;
}
sub parse_dbs{
    my $file = shift;

    my $hsh;
    my @dbs = read_file($opts{genomes_list});
    
    my $count = 1;
    foreach my $db (@dbs){
	$db =~ s/\s+$//;
	$hsh->{$count} = $db;
	$count++;
    }

    return $hsh;
}
sub check_params{
    my $error;

    if(!($opts{matchtable} && $opts{genomes_list} && $opts{att_file})){
	$error .= "Must supply --matchtable, --genomes_list and --att_file\n";
    }else{
	$error .= "$opts{matchtable} does not exist or is size zero\n" unless (-s $opts{matchtable});
	$error .= "$opts{genomes_list} does not exist or is size zero\n" unless (-s $opts{genomes_list});
	$error .= "$opts{att_file} does not exist or is size zero\n" unless (-s $opts{att_file});
    }
    
    if($opts{output}){
	mkpath($opts{output}) unless(-d $opts{output});
	$OUTPUT_DIR = $opts{output};
    }else{ 
	$OUTPUT_DIR = cwd();
    }

    die($error) if $error;
}
