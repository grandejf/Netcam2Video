#!/usr/bin/perl -w

use strict;
use Time::Local;
use POSIX;
use File::Copy;

# crontab:
# 5 0 * * * cd /DataVolume/shares/Netcam; perl -w compress_to_mp4.pl >>compress_to_mp4.log 2>&1

my $root = '/DataVolume/shares/Netcam';
my @dirs = ("$root/pancam1/motion",
            "$root/pancam1/timer",
            "$root/pancam2/motion",
            "$root/pancam2/timer");

foreach my $dir (@dirs) {
  my $stoptime;
  $stoptime = time();
  $stoptime = timelocal(0, 0, 0, (localtime($stoptime))[3], (localtime($stoptime))[4], (localtime($stoptime))[5]);
  my $threshold = 60*60*24;
  my ($type) = ($dir =~ m!/([^/]+)$!o);
  if ($type eq 'motion') {
    $threshold = 60*10;
    $stoptime = 0;
  }
  if (opendir (DIR, $dir)) {
    my @filenames;
    while (my $filename = readdir(DIR)) {
      push @filenames, $filename if $filename =~ /\.jpg$/o;
    }
    closedir (DIR);
    @filenames = sort @filenames;
    my %batches;
    my $laststart = 0;
    my $lastts = 0;
    foreach my $filename (@filenames) {
      my ($year,$mon,$mday,$hour,$min,$sec,$msec) = ($filename =~ /(\d{4})(\d{2})(\d{2})s(\d{2})(\d{2})(\d{2})(\d+)\.jpg/o);
      my $ts = timelocal($sec, $min, $hour, $mday, $mon-1, $year);
      next if $stoptime && $ts>$stoptime;
      if ($ts - $lastts > $threshold) {
        $laststart = $ts;
      }
      $lastts = $ts;
      push @{$batches{$laststart}}, $filename;
    }
    foreach my $ts (sort keys %batches) {
      if (! -d "$dir/tmp") {
        mkdir("$dir/tmp");
      }
      my $count = 1;
      my @tmpfiles;
      foreach my $filename (@{$batches{$ts}}) {
        my $tfilename = sprintf("tmp%08d.jpg", $count);
        my $tpath = "$dir/tmp/$tfilename";
        push @tmpfiles, $tpath;
        copy("$dir/$filename",$tpath) or die "copy failed $!";
        $count++;
      }
      next unless scalar(@tmpfiles) > 1;
      my $outdir = "$dir/../$type" . "_video";
      if (! -d $outdir) {
        mkdir($outdir);
      }
      $outdir .= strftime("/%Y%m%d", localtime($ts));
      if (! -d $outdir) {
        mkdir($outdir);
      }
      my $ofilename = strftime("%Y%m%d-%H%M%S.mov", localtime($ts));
      my $out = `ffmpeg -y -r 3 -vcodec copy -i $dir/tmp/tmp%08d.jpg $outdir/$ofilename 2>&1`;
      if ($out =~ /error/om) {
        print "$out\n";
        die;
      }
      foreach my $filename (@tmpfiles) {
        unlink($filename);
      }
      foreach my $filename (@{$batches{$ts}}) {
        unlink("$dir/$filename");
      }
    }
  }
}
