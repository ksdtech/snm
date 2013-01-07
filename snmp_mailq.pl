#!/usr/bin/perl -w

# 'mailq',  'requests.0' , 'size.0'
my @oids = qw( .1.3.6.1.4.1.14697.101 .1.3.6.1.4.1.14697.101.1.0  .1.3.6.1.4.1.14697.101.2.0);  

my ($action, $oid) = @ARGV;
my $response;
if ($action eq '-n') {
    if ($oid eq $oids[0])    { $oid = $oids[1]; $action = '-g'; }
    elsif ($oid eq $oids[1]) { $oid = $oids[2]; $action = '-g'; }
}
if ($action eq '-g') {
  if ($oid eq $oids[1] || $oid eq $oids[2]) {
    my @lines = `/usr/bin/mailq`;
    my $last = pop @lines;
    if ($last =~ m/(\d+)\s+(\w+)\s+in\s+(\d+)/) {
      my $size  = $1;
      my $units = $2;
      my $reqs  = $3;
      if ($oid eq $oids[1]) { $response = "$oid\ngauge\n$reqs\n"; } 
      else { $response = "$oid\ngauge\n$size\n"; }
    }
  }
} elsif ($action eq '-s') {
  $response = "not-writable\n";
}

print $response if $response;
