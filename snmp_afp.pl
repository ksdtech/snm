#!/usr/bin/perl -w

# get_connections_cmd.txt
# afp:command = getHistory
# afp:variant = v1
# afp:timeScale = 300

# get_throughput_cmd.txt
# afp:command = getHistory
# afp:variant = v1
# afp:timeScale = 300

use FindBin qw($Bin);

my $my_dir = $Bin;
sub get_connections {
    open(SA, "/usr/sbin/serveradmin command <$my_dir/get_connections_cmd.txt |");
    my @lines = <SA>;
    close(SA);
    &process_data(1, @lines);
}

sub get_throughput {
    open(SA, "/usr/sbin/serveradmin command <$my_dir/get_throughput_cmd.txt |");
    my @lines = <SA>;
    close(SA);
    &process_data(0, @lines);
}

# afp:currentServerTime = 1161615291
# afp:v2Legend = "THROUGHPUT"
# afp:nbSamples = 5
# afp:v1Legend = "CONNECTIONS"
# afp:samplesArray:_array_index:0:v2 = 16451
# afp:samplesArray:_array_index:0:t = 1161615233
# afp:samplesArray:_array_index:1:v2 = 3
# afp:samplesArray:_array_index:1:t = 1161615173
# afp:samplesArray:_array_index:2:v2 = 151761
# afp:samplesArray:_array_index:2:t = 1161615114
# afp:samplesArray:_array_index:3:v2 = 119651
# afp:samplesArray:_array_index:3:t = 1161615053
# afp:samplesArray:_array_index:4:v2 = 44
# afp:samplesArray:_array_index:4:t = 1161614993

sub process_data {
  my ($t0, $t1);
  my $total = 0;
  my $n = 0;
  my $max = shift;
  foreach (@_) {
    if (m/afp:samplesArray:_array_index:(\d+):(t|v\d+)\s+=\s+(\d+)/) {
      if ($2 eq 't') {
        $t1 = $3;
        $t0 = $3 unless defined($t0);
      } else {
        $total += $3;
        $n += 1;
        last if ($max != 0 && $n >= $max);
      }
    } 
  }
  if ($n != 0) {
    return $total if ($n == 1);
    return $total/$n;
  }
  return undef;
}

# 'afp',  'connections.0' , 'throughput.0'
my @oids = qw( .1.3.6.1.4.1.14697.102 .1.3.6.1.4.1.14697.102.1.0  .1.3.6.1.4.1.14697.102.2.0);  

my ($action, $oid) = @ARGV;
my $response;
if ($action eq '-n') {
    if ($oid eq $oids[0])    { $oid = $oids[1]; $action = '-g'; }
    elsif ($oid eq $oids[1]) { $oid = $oids[2]; $action = '-g'; }
}
if ($action eq '-g') {
  my $data;
  if ($oid eq $oids[1]) {
    $data = &get_connections;
  } elsif ($oid eq $oids[2]) {
    $data = &get_throughput;
  }
  if (defined($data)) {
    $response = "$oid\ngauge\n$data\n";
  }
} elsif ($action eq '-s') {
  $response = "not-writable\n";
}

print $response if $response;
