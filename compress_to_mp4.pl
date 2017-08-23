#!/usr/bin/perl -w

use strict;
use Time::Local;
use POSIX;
use File::Copy;
use Net::FTP;
use Fcntl qw(:flock);

# crontab:
# run every 5 minutes from midnight until 1am in case in case cron wasn't running
# */5 0 * * * umask 002; cd /DataVolume/shares/Netcam; perl -w compress_to_mp4.pl --beforeTime 0000 >>compress_to_mp4.log 2>&1
#
# on pogoplug
# */10 0 * * * cd /home/pancam/Netcam; perl -w compress_to_mp4.pl --root . --beforeTime 0000 --upload 192.168.1.103

my $beforeTime;
my $root;
my $upload;
my $oldvideos = 0;
my @newargs;
while (@ARGV) {
  my $arg = shift @ARGV;
  if ($arg =~ /^--beforeTime/oi) {
    $beforeTime = shift @ARGV;
    next;
  }
  if ($arg =~ /^--root/oi) {
    $root = shift @ARGV;
    next;
  }
  if ($arg =~ /^--upload/oi) {
    $upload = shift @ARGV;
  }
  if ($arg =~ /^--oldvideos/oi) {
    $oldvideos = 1;
  }
  push @newargs, $arg;
}
@ARGV = @newargs;


my $pidfile = "compress_to_mp4.pl.pid";
if (open(PID,">>$pidfile")) {
  flock PID, LOCK_EX|LOCK_NB or die "Already running\n";
  select((select(PID), $| = 1)[0]);
  truncate PID, 0;
  print PID "$$\n";
}

if ($beforeTime) {
  my ($h, $m) = ($beforeTime =~ /^(\d\d):?(\d\d)$/);
  die "Bad time: $beforeTime\n" unless defined($h) && defined($m);
  $beforeTime = time();
  $beforeTime = timelocal(0, $m, $h, (localtime($beforeTime))[3], (localtime($beforeTime))[4], (localtime($beforeTime))[5]);
}

$root ||= '/DataVolume/shares/Netcam';
my @dirs = ("$root/pancam1/motion",
            "$root/pancam1/timer",
            "$root/pancam2/motion",
            "$root/pancam2/timer",
            "$root/pancam3/motion",
            "$root/pancam3/timer",
            "$root/pancam4/motion",
            "$root/pancam4/timer",
    );

my @videofiles;

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
  $stoptime = $beforeTime if $beforeTime;
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
      if (!defined($msec)) {
        ($year,$mon,$mday,$hour,$min,$sec,$msec) = ($filename =~ /[^0-9](\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d+)\.jpg/o);
      }
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
      $outdir .= strftime("/%Y", localtime($ts));
      if (! -d $outdir) {
        mkdir($outdir);
      }
      $outdir .= strftime("/%Y%m", localtime($ts));
      if (! -d $outdir) {
        mkdir($outdir);
      }
      $outdir .= strftime("/%Y%m%d", localtime($ts));
      if (! -d $outdir) {
        mkdir($outdir);
      }
      my $ofilename;
      my $out = '';
      if (supports_mpeg4()) {
        $ofilename = strftime("%Y%m%d-%H%M%S.mp4", localtime($ts));
        $out = `/usr/local/bin/ffmpeg -y -r 3 -i $dir/tmp/tmp%08d.jpg -vcodec mpeg4 -b 400k $outdir/$ofilename 2>&1`;
      }
      else {
        $ofilename = strftime("%Y%m%d-%H%M%S.mov", localtime($ts));
        $out = `/usr/local/bin/ffmpeg -y -r 3 -vcodec copy -i $dir/tmp/tmp%08d.jpg $outdir/$ofilename 2>&1`;
      }
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
      push @videofiles, "$outdir/$ofilename";
    }
  }
}

if ($oldvideos) {
  foreach my $dir (@dirs) {
    $dir .= '_video';
    foreach my $filename (`find $dir -name "*.mp4"`) {
      chomp($filename);
      push @videofiles, $filename;
    }
  }
}

if ($upload && @videofiles) {
  uploadVideos($upload, \@videofiles);
}

sub supports_mpeg4
{
  if (`/usr/local/bin/ffmpeg -codecs 2> /dev/null |grep mpeg4 |grep EV`) {
    return 1;
  }
  return 0;
}

sub uploadVideos
{
  my ($remoteserver,$videofiles) = @_;
  my $user;
  my $pass;
  open(CONFIG,"config.ini");
  while (<CONFIG>) {
    chomp;
    my $line = $_;
    my ($key, $val) = ($line =~ /^\s*(\S+?)\s*=\s*(.*?)\s*$/o);
    if ($key && $val) {
      if ($key eq 'user') {
        $user = $val;
      }
      if ($key eq 'password') {
        $pass = $val;
      }
    }
  }
  close CONFIG;
  foreach my $source (@{$videofiles}) {
    my ($dest,$filename) = ($source =~ m!(.*)/(.+?)$!o);
    next unless -f $source;
    $dest = cleanpath($dest);
    my $ftp = Net::FTP->new($remoteserver, Debug=>0) or die "Couldn't connect to $remoteserver: $@\n";
    $ftp->login($user,$pass) or die "Couldn't login ", $ftp->message;
    $ftp->binary();
    $ftp->cwd("Netcam") or die $ftp->message;
    if (!$ftp->cwd($dest)) {
      $ftp->mkdir($dest,1) or die "Couldn't create $dest", $ftp->message;
      $ftp->cwd($dest) or die "Couldn't cd into $dest", $ftp->message;
    }
    if ($ftp->put($source,$filename)) {
      unlink($source);
    }
    else {
      die "Couldn't upload $source -> $filename", $ftp->message;
    }
    $ftp->quit();
  }

}

sub cleanpath
{
  my ($in) = @_;
  my @out;
  foreach my $p (split /\//, $in) {
    if ($p eq '..') {
      pop @out;
    }
    elsif ($p eq '.') {
    }
    else {
      push @out, $p;
    }
  }
  return join "/", @out;
}
