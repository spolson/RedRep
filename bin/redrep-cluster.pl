#!/usr/bin/perl

my $ver="redrep-cluster.pl Ver. 2.3 [08/13/2020 rev]";
my $script=join(' ',@ARGV);

use strict;

die "ERROR: RedRep Installation Environment Variables not properly defined: REDREPLIB.  Please check your redrep.profile REDREP_INSTALL setting and make sure that file is sourced.\n" unless($ENV{'REDREPLIB'} && -e $ENV{'REDREPLIB'} && -d $ENV{'REDREPLIB'});
die "ERROR: RedRep Installation Environment Variables not properly defined: REDREPUTIL.  Please check your redrep.profile REDREP_INSTALL setting and make sure that file is sourced.\n" unless($ENV{'REDREPUTIL'} && -e $ENV{'REDREPUTIL'} && -d $ENV{'REDREPUTIL'});
die "ERROR: RedRep Installation Environment Variables not properly defined: REDREPBIN.  Please check your redrep.profile REDREP_INSTALL setting and make sure that file is sourced.\n" unless($ENV{'REDREPBIN'} && -e $ENV{'REDREPBIN'} && -d $ENV{'REDREPBIN'});

use lib $ENV{'REDREPLIB'};
use RedRep::Utils;
#use RedRep::Utils qw();
use Getopt::Long qw(:config no_ignore_case);
use Carp qw(cluck confess longmess);
use Pod::Usage;
use File::Basename qw(fileparse);
use File::Copy qw(copy move);
use File::Copy::Recursive qw(dircopy);
use File::Path qw(make_path remove_tree);
use File::Which qw(which);
use Filesys::Df qw(df);
use Sys::Hostname qw(hostname);

sub binClass;
sub centroid_rename;

### ARGUMENTS WITH NO DEFAULT
our($outDir,$intermed,$tmpdir,$debug,$no_stage_intermed,$tmp_in_outdir); 	# globals to properly handle file unstaging in case of fatal errors
my($inFile,$inFile2,$help,$manual,$force,$version,$hist_stats,$stage);
our($keep);

### ARGUMENTS WITH DEFAULT
my $logOut;										# default post-processed
my $ncpu				=	1;
my $id					=	0.98;
my $minlen			=	35;
my $minqual			=	20;
my $minsize			=	1;
my $sizeBinStart=	1;
my $sizeBinSize = 250;
my $sizeBinNum	=	50;
my $sizeBinEnd	=	999999999;	# hard-coded max
my $lenBinStart	=	81;
my $lenBinSize 	= 5;
my $lenBinNum		=	4;
my $lenBinEnd		= 999;				# hard-coded max
our $verbose		= 4;


GetOptions (
	"1|i|in|in1=s"				=>	\$inFile,
	"2|in2=s"							=>	\$inFile2,
	"o|out=s"							=>	\$outDir,
	"l|log=s"							=>	\$logOut,

	"f|force"							=>	\$force,
	"d|debug:+"						=>	\$debug,
	"k|keep|keep_temp"		=>	\$keep,
	"V|verbose:+"					=>	\$verbose,

	"c|p|id=s"						=>	\$id,
	"n|minlen=i"					=>	\$minlen,
	"q|minqual=f"					=>	\$minqual,
	"minsize=i"						=>	\$minsize,

	"hist_stats"					=>	\$hist_stats,
	"size_bin_start=i"		=>	\$sizeBinStart,
	"size_bin_num=i"			=>	\$sizeBinNum,
	"size_bin_width=i"		=>	\$sizeBinSize,
	"len_bin_start=i"			=>	\$sizeBinStart,
	"len_bin_num=i"				=>	\$lenBinNum,
	"len_bin_width=i"			=>	\$lenBinSize,

	"t|threads|ncpu=i"		=>	\$ncpu,
	"T|tmpdir=s"					=>	\$tmpdir,
	"S|stage"							=>	\$stage,
	"tmp_in_outdir"				=>	\$tmp_in_outdir,

	"v|ver|version"				=>	\$version,
	"h|help"							=>	\$help,
	"m|man|manual"				=>	\$manual);


### VALIDATE ARGS
pod2usage(-verbose => 2)  if ($manual);
pod2usage(-verbose => 1)  if ($help);
die "\n$ver\n\n" if ($version);
pod2usage( -msg  => "ERROR!  Required argument -i (input file 1) not found.\n", -exitval => 2) if (! $inFile);
pod2usage( -msg  => "ERROR!  Required argument -o (output directory) not found.\n", -exitval => 2)  if (! $outDir);


### DEBUG MODE
if($debug) {
	require warnings; import warnings;
	$keep=1;
	$verbose=10;
	if($debug>1) {
		$verbose=100;
		require Data::Dumper; import Data::Dumper;
		require diagnostics; import diagnostics;
	}
	$tmp_in_outdir=1 if($debug>2);
}


### SET DEFAULT METHOD OF FILE PROPAGATION
my $mv = \&move;
if($keep)
{	$mv = \&copy;
}


# Make sure hist bin size parameters in spec
$sizeBinEnd=($sizeBinSize*$sizeBinNum)+$sizeBinStart+99 if(($sizeBinSize*$sizeBinNum)+$sizeBinStart > $sizeBinEnd);
$lenBinEnd=($lenBinSize*$lenBinNum)+$lenBinStart+99 if(($lenBinSize*$lenBinNum)+$lenBinStart > $lenBinEnd);


### DECLARE OTHER GLOBALS
my $sys;												# system call variable
my $stub=fileparse($inFile, qr/\.[^.]*(\.gz)?$/);


### THROW ERROR IF OUTPUT DIRECTORY ALREADY EXISTS (unless $force is set)
if(-d $outDir)
{	if(! $force)
	{	pod2usage( -msg  => "ERROR!  Output directory $outDir already exists.  Use --force flag to overwrite.", -exitval => 2);
	}
	else
	{	$sys=remove_tree($outDir);
	}
}


### CREATE OUTPUT DIR AND OPEN LOG
mkdir($outDir) || confess("ERROR: Can't create output directory $outDir");
$logOut="$outDir/log.cluster.txt" if (! $logOut);
open(our $LOG, "> $logOut");
logentry("SCRIPT STARTED ($ver)",2);


### OUTPUT FILE LOCATIONS
$tmpdir								=	get_tmpdir($tmpdir);
$intermed							=	"$tmpdir/intermed";
$intermed							=	"$outDir/intermed" if($tmp_in_outdir);

mkdir($intermed);


### INITIATE LOG
logentry("Command: $0 $script\n",2);
logentry("Executing on ".hostname."\n",2);
logentry(find_job_info(),2);
logentry("Output directory $outDir (" . sprintf("%.2f",df("$outDir",1073741824)->{'bfree'}) . " GB free)\n",2);
logentry("Temporary directory $tmpdir (" . sprintf("%.2f",df("$tmpdir",1073741824)->{'bfree'}) . " GB free)\n",2);
logentry("Log verbosity: $verbose\n",2) if($verbose && $verbose>0);
logentry("Running in Debug Mode $debug\n",2) if($debug && $debug>0);
logentry("Keeping intermediate files.  WARNING: Can consume significant extra disk space\n",2) if($keep && $keep>0);


### REDREP BIN/SCRIPT LOCATIONS
my $execDir=$ENV{'REDREPBIN'};
my $utilDir=$ENV{'REDREPUTIL'};
my $libDir=$ENV{'REDREPLIB'};
logentry("RedRep Bin: $execDir\n",2);
logentry("RedRep Utilities: $utilDir\n",2);
logentry("RedRep Libraries: $libDir\n",2);


### TEMPORARILY DISABLE HISTSTATS
if($hist_stats==1) {
	print "hist_stats function temporarily disabled in this version.  Will be reimplemented in future.\n";
	logentry("hist_stats function temporarily disabled in this version.  Will be reimplemented in future.\n",1);
	$hist_stats=0;
}


### BIN/SCRIPT LOCATIONS
my $sort_fastq_sh="$utilDir/sort-fastq.sh";
my $fastq2fasta_pl="$utilDir/fastq2fasta.pl";
my $fasta_abbrev_pl="$utilDir/fasta-abbrev.pl";
my $CDHitClustComp_pl="$utilDir/CDHitClustComp.pl";
#my $usearch5="$execDir/usearch5";
#my $usearch8="$execDir/usearch8";
my $clstr_sort_by_pl=which "clstr_sort_by.pl";
my $clstr_sort_prot_by_pl=which "clstr_sort_prot_by.pl";
my $plot_len1_pl=which "plot_len1.pl";


### CHECK FOR EXTERNAL DEPENDENCIES
logentry("Checking External Dependencies",3);

my $usearch=check_dependency("usearch","--version","s/\r?\n/ | /g",1);
my $uclust=check_dependency("uclust","--version","s/\r?\n/ | /g",1);
my $clstr_sort_by_pl=check_dependency("$clstr_sort_by_pl");
my $clstr_sort_prot_by_pl=check_dependency("$clstr_sort_prot_by_pl");
my $usearch5=$uclust;

### OUTPUT FILE LOCATIONS
my $fq_sorted="$intermed/$stub.sort.fastq";
my $fasta_sorted="$intermed/$stub.sort.fasta";
my $fasta_header="$intermed/$stub.sort.header.txt";
my $fasta_sorted_abbrev="$intermed/$stub.sort.abbrev.fasta";
my $splitDir="$intermed/split";
my $uc_centroid="$intermed/$stub.uc.centroid.fasta";
my $uc_centroid_filter="$intermed/$stub.uc.centroid.filter.fasta";
my $uc_centroid_ren="$intermed/$stub.uc.centroid.clean.fasta";
my $uc_centroid_filter_ren="$intermed/$stub.uc.centroid.clean.filter.fasta";
my $uc_consensus="$intermed/$stub.uc.consensus.fasta";
my $uc_seeds="$intermed/$stub.uc.seeds.fasta";
my $uc_uc="$outDir/$stub.uc";
my $uc_uc_seeds="$intermed/$stub.seeds.uc";
my $uc_uc_clusters="$outDir/$stub.cluster-list.sorted.uc";
my $uc_clstr="$intermed/$stub.uc.clstr";
my $uc_hist_stats="$outDir/$stub.hist_stats.tsv";
my $uc_cluster_freq="$outDir/$stub.cluster_freq.tsv";


############
### MAIN

	logentry("PREPARE INPUT FILES",3);
	logentry("SORT FASTQ FILE",4);
	$sys=cmd("$sort_fastq_sh $inFile $fq_sorted $minlen $minqual","Sort fastq file");
	logentry("CONVERT FASTQ TO FASTA FORMAT",4);
	$sys=cmd("$fastq2fasta_pl $fq_sorted > $fasta_sorted","Convert fastq to fasta");
	logentry("ABBREVIATE FASTA FILE",4);
	$sys=cmd("$fasta_abbrev_pl $fasta_sorted $fasta_sorted_abbrev $fasta_header","Abbreviate fasta headers");

	# Split Fasta File if larger than 4GB
	my $filesize=-s $fasta_sorted_abbrev;
	my $slice=$fasta_sorted_abbrev;
	my $upperlim=3950000000;							# maximum size of an input file size to maintain 32bit usearch, 4GB capacity
	my $lowerlim=$upperlim*0.99;					# minimum threshold of file size to trigger next split
	my $sizeinout="-sizein -sizeout";     # value to use if file doesn't need to split . . . variable may be depracated as sizein is always included now from fasta_abbrev

	logentry("BEGIN CLUSTERING",3);
	if($filesize > $upperlim)
	{	#Abbrev fasta will always have an abbreviated header and 1 line sequence due to fasta-abbrev.pl processing
		open(DAT,"$fasta_sorted_abbrev");
		my $it=1;
		my $slicesize;
		$sys=cmd("mkdir $splitDir$it","Make split $it directory");
		$slice="$splitDir$it/$it.fasta";
		logentry("PRODUCING FASTA SPLIT $it",4);
		open(SUB, ">$slice");
		while(<DAT>)
		{	$slicesize+=length($_);
			print SUB $_;
			my $tmp=<DAT>;
			$slicesize+=length($tmp);
			print SUB $tmp;
			if($slicesize>$lowerlim)
			{	close(SUB);
				logentry("RUNNING UCLUST SPLIT $it",4);
				$sizeinout="-sizein -sizeout";  # may be depracated . . . all lines will have sizein due to fasta_abbrev
				$sys=cmd("$usearch --cluster_smallmem $slice --leftjust $sizeinout --id $id --centroids $splitDir$it/$it.centroid --uc $splitDir$it/$it.uc --log $splitDir$it/uclust_$it.log --sortedby 'other'","UCLUST FASTA SPLIT $slice");
				$slice="$splitDir$it/$it.centroid";
				$it++;
				$sys=cmd("mkdir $splitDir$it","Make split $it directory");
				$sys=cmd("cp $slice $splitDir$it/$it.fasta","Roll over slice input");
				$slice="$splitDir$it/$it.fasta";
				logentry("PRODUCING FASTA SPLIT $it",4);
				open(SUB, ">>$slice");
				$slicesize=-s $slice;      #record size of output file and use as base size for next slice
				pod2usage( -msg  => "Size of input file exceeds capability of 32-bit usearch.\n", -exitval => 2) if ($slicesize>$lowerlim);
			}
		}
		close(SUB);
	}

	# UCLUST IF SMALLER THAN 4GB OR FINAL SPLIT
	logentry("RUNNING UCLUST FINAL",4);
	$sys=cmd("$usearch --cluster_smallmem ${slice} --leftjust $sizeinout --id $id --centroids $uc_centroid --uc $uc_uc --log $outDir/uclust_final.log --sortedby 'other'","UCLUST FINAL RUN: $slice");
	$sys=cmd("$usearch --sortbysize $uc_centroid --fastaout $uc_centroid_filter --minsize $minsize","UCLUST CENTROID FILTER FINAL RUN: $slice") if($minsize>1);

	$sys=cmd("grep '^S' $uc_uc | sort -k2,2 -n > $uc_uc_seeds","Make seeds uc file");
	$sys=cmd("grep '^C' $uc_uc | sort -k3,3 -nr > $uc_uc_clusters","Make sorted seeds uc file");



	if($hist_stats)
	{	logentry("PREPARE STATS",3);
		##### THIS BLOCK USED TO BE BEFORE IF
		$sys=cmd("$usearch5 --uc2fasta $uc_uc_seeds --input $fasta_sorted_abbrev --output $uc_seeds","Make seeds fasta file");

		# CONVERT UC TO CLSTR
		logentry("CONVERT UC FILE TO CLSTR FORMAT",4);
		$sys=cmd("$usearch5 --uc2clstr $uc_uc --output $uc_clstr","Convert uc to clstr format");

		# SORT CLUSTERS
		logentry("SORT CLUSTERS BY SIZE",4);
		$sys=cmd("$clstr_sort_by_pl $uc_clstr no > $uc_clstr.tmp","Sort clusters by size");
		logentry("SORT CLUSTERS BY SEED LENGTH",3);
		$sys=cmd("$clstr_sort_prot_by_pl len $uc_clstr.tmp > $uc_clstr.sort","Sort clusters by sequence length");

    ##### END BLOCK

		# DEFINE CLUSTER SIZE BINS FOR STATS
		my $sizeBinStr;
		for (my $j=0;$j<$sizeBinNum; $j++)
		{	$sizeBinStr .= "," if($sizeBinStr);
			$sizeBinStr .= binClass($j,$sizeBinSize,$sizeBinStart);
		}
		{	$sizeBinStr .= "," if($sizeBinStr);
			my $bottom=($sizeBinNum*$sizeBinSize)+$sizeBinStart;
			my $top=$sizeBinEnd;
			$sizeBinStr .= $bottom."-".$top;
		}

		# DEFINE CLUSTER LENGTH BINS FOR STATS
		my $lenBinStr;
		for (my $j=0;$j<$lenBinNum; $j++)
		{	$lenBinStr .= "," if($lenBinStr);
			$lenBinStr .= binClass($j,$lenBinSize,$lenBinStart);
		}
		{	$lenBinStr .= "," if($lenBinStr);
			my $bottom=($lenBinNum*$lenBinSize)+$lenBinStart;
			my $top=$lenBinEnd;
			$lenBinStr .= $bottom."-".$top;
		}

		# RUN HISTOGRAM STATS
		logentry("RUN HISTOGRAM (CLUSTER SIZE/LENGTH) STATS",4);
		$sys=cmd("$plot_len1_pl $uc_clstr.sort \\$sizeBinStr \\$lenBinStr > $uc_hist_stats","Run Cluster Stats (Histogram)");
	}
	else
	{	logentry("SKIPPING HISTOGRAM (CLUSTER SIZE/LENGTH) STATS",2);
	}

#	# PARSE CLUSTER COUNTS
#	logentry("PARSE CLUSTER COUNTS",3);
#	$sys=cmd("$CDHitClustComp_pl $uc_clstr $uc_cluster_freq","Parse Cluster Counts");

	# PRODUCE CLEAN CENTROID FILE (size= attributes removed)
	logentry("CLEANING CENTROID OUTPUT FILES",3);
	centroid_rename($uc_centroid, $uc_centroid_ren);
	centroid_rename($uc_centroid_filter, $uc_centroid_filter_ren) if(-e $uc_centroid_filter);


	### FILE CLEAN UP
	logentry("FILE CLEAN UP",3);
#	$sys=&$mv($uc_clstr.sort,$outDir);
	$sys=&$mv($uc_centroid_ren,$outDir);
	$sys=&$mv($uc_centroid_filter_ren,$outDir) if(-e $uc_centroid_filter);


	### STANDARD FILE CLEAN UP
	if($keep && ! $tmp_in_outdir) {
		logentry("Saving intermediate tmp directory",4);
		$sys=dircopy($intermed, "$outDir/intermed");
	}
	logentry("Removing tmp files",4);
	$sys=remove_tree($tmpdir);


	### WRAP UP
	logentry("SCRIPT COMPLETE",2);
	logentry("TOTAL EXECUTION TIME: ".script_time(),2);
	close($LOG);


exit 0;


#######################################
############### SUBS ##################


#######################################
### binClass
#
sub binClass
{	my $number=shift;
	my $size=shift;
	my $start=shift;

	my $bottom=$start+($number*$size);
	my $top=($start+(($number+1)*$size))-1;
	return $bottom."-".$top;
}


#######################################
### centroid_rename
# rename sequences in a usearch centroid file to remove ;size= attribute
sub centroid_rename
{  my $infile=shift;
   my $outfile=shift;

   open(CEN_IN, $infile);
   open(CEN_OUT, "> $outfile");

   while(<CEN_IN>)
   {  s/;size=\d+;//;
      print CEN_OUT $_;
   }

   close(CEN_IN);
   close(CEN_OUT);
}


__END__


#######################################
########### DOCUMENTATION #############
=pod

=head1 NAME

redrep-cluster.pl -- De novo clustering of reduced representation libraries

=head1 SYNOPSIS

 redrep-cluster.pl --in FILENAME --out DIRNAME [PARAMETERS]
                     [--help] [--manual]
=head1 DESCRIPTION

Accepts fastq output from redrep-qc.pl and performs clustering of reduced representaiton tags without a priori reference.

=head1 OPTIONS

=head2 REQUIRED PARAMETERS

=over 3

=item B<-1, -i, --in, --in1>=FILENAME

Input file (single file or first read) in fastq format. (Required)

=item B<-o, --out>=DIRECTORY_NAME

Output directory. (Required)

=back

=head2 OPTIONAL PARAMETERS

=head3 Program Specific Parameters

=head4 General Clustering Parameters

=over 3

=item B<-c, -p, --id>

Minimum identity cutoff for clustering (Default=0.98)

=item B<-n, --minlen>

Minimum length for a cluster seed sequence (Default=35)

=item B<-q, --minqual>

Minimum quality for a cluster seed sequence (Default=20)

=item B<--minsize>

Minimum cluster size

=back

=head4 Histogram Statistics Parameters

=over 3

=item B<--hist_stats>

Run the histogram statistics.  May dramatically SLOW execution time.  [hist_stats Function Temporarily Disabled in this Version]

=item B<--size_bin_start>

Starting size of histogram bins for cluster size statistics (default=1)  [hist_stats Function Temporarily Disabled in this Version]

=item B<--size_bin_num>

Number of histogram bins for cluster size statistics (default=50)  [hist_stats Function Temporarily Disabled in this Version]

=item B<--size_bin_width>

Width of histogram bins for cluster size statistics (default=250)  [hist_stats Function Temporarily Disabled in this Version]

=item B<--len_bin_start>

Starting size of histogram bins for cluster seed length statistics (default=81)  [hist_stats Function Temporarily Disabled in this Version]

=item B<--len_bin_num>

Number of histogram bins for cluster seed length statistics (default=4)  [hist_stats Function Temporarily Disabled in this Version]

=item B<--len_bin_width>

Width of histogram bins for cluster seed length statistics (default=5)  [hist_stats Function Temporarily Disabled in this Version]

=back

=head3 Program Behavior and Resource Control

=over 3

=item B<-f, --force>

If output directory exists, force overwrite of previous directory contents.

=item B<-k, --keep>

Retain temporary intermediate files.

=item B<-S, --stage>

When specified, input files will be staged to the tmpdir.  Can increase performance on clusters and other situations where the output directory is on network attached or cloud storage.

=item B<-T, --tmpdir>

Set directory (local directory recommended) for fast temporary and staged file operations.  Defaults to system environment variable REDREP_TMPDIR, TMPDIR, TEMP, or TMP in that order (if they exist).  Otherwise assumes /tmp.

=back

=head3 Logging Parameters

=over 3

=item B<-l, --log>=FILENAME

Log file output path. [ Default output-dir/log.cluster.txt ]

=item B<-V, --verbose>[=integer]

Produce detailed log.  Can be involed multiple times for additional detail levels or level can be specified. 0: ERROR, 1: WARNINGS, 2: INFO, 3-6: STATUS LEVELS, 7+:DEBUGGING INFO (default=4)

=back

=head3 Help

=over 3

=item B<-h, --help>

Displays the usage message.

=item B<-m, --man, --manual>

Displays full manual.

=item B<-v, --ver, --version>

Displays the current version.

=back

=head1 VERSION HISTORY

=over 3

=item 0.0 - 11/5/2012: Draft1

=item 1.0 - 12/5/2012: Release

=item 1.1 - 1/31/2013: Default is now to NOT run hist stats

=item 1.2 - 3/28/2014: Added dependency version to log; import $REDREPBIN from ENV

=item 1.3 - 11/3/2015: Add minsize (minimum cluster size) option

=item 2.0 = 11/21/2016: Remove size attribute from centroid fasta files -- avoids GATK issue.  Major version release.

=item 2.01 = 1/20/2017: Minor code cleanup.

=item 2.1 = 2/1/2017: Major code cleanup including minimizing OS dependencies

=item 2.11 = 10/9/2019: Minor code cleanup.  Verbosity settings added.  Added -sorted_by to usearch commands to be compatible with recent versions.  Last version with GATK 3.x compatibility.

=item 2.2 - 10/28/2019: Many enhancements including parallelization, documentation, and logging.

=item 2.3 - 8/1/2020: Fixed disk space reporting bugs.

=back

=head1 DEPENDENCIES

=head2 Requires the following external programs be in the system PATH:

=over 3

=item usearch/uclust (ver 5.x or earlier)

=item usearch (tested with version v11.0.667_i86linux32; must be accessible in the system PATH as "usearch8"))

=back

=head1 AUTHOR

Written by Shawn Polson, University of Delaware

=head1 REPORTING BUGS

Report bugs to polson@udel.edu

=head1 COPYRIGHT

Copyright 2012-2020 Shawn Polson, Randall Wisser, Keith Hopper.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.

Please acknowledge author and affiliation in published work arising from this script's
usage <http://bioinformatics.udel.edu/Core/Acknowledge>.

=cut
