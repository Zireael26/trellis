#!/usr/bin/perl
# trellis heavy supervisor (spec 054). scripts/heavy.sh validates the argument
# shape and then execs this file; it never returns to a shell.
#
#   heavy-supervisor.pl run    POOL LANE TIMEOUT CMD...
#   heavy-supervisor.pl check
#   heavy-supervisor.pl status
#
# A slot is a flock(2) lock on $TRELLIS_HOME/locks/heavy/slot-<i>.lock (the
# heavy pool) or light-<i>.lock (the light pool, Amendment A1). The pools never
# borrow from each other; everything else below applies to each alike. The
# kernel releases it when the last copy of the open file description closes,
# so there is no reclaim protocol: a dead holder frees its slot by dying.
#
# The supervisor holds the lock for the whole run. It puts the workload in its
# own process group and supervises until that group is empty, keeping the
# group leader an unreaped zombie meanwhile so the group ID cannot be reused
# while teardown may still signal it. The descriptor is also handed to the
# workload (dup'd to >= 64, FD_CLOEXEC cleared) as a safeguard for the case
# where the supervisor itself is SIGKILLed.
#
# Scope: accounting for well-behaved workloads, not a sandbox. A descendant
# that calls setsid, or leaves the group some other way, escapes the count.
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock F_DUPFD F_GETFD F_SETFD);
use POSIX qw(SIGINT SIGTERM SIGHUP SIG_BLOCK SIG_UNBLOCK WNOHANG);
use JSON::PP ();
use MIME::Base64 ();
use Time::HiRes ();

my $EX_USAGE       = 2;
my $EX_UNAVAILABLE = 5;
my $EX_CONFIG      = 78;
my $EX_TIMEOUT     = 124;
my %SIGNUM         = (INT => SIGINT, TERM => SIGTERM, HUP => SIGHUP);

# Files this holder has published under its lock. Every exit that can follow
# publication goes through fail() or an explicit unlink, so they are removed
# while the lock is still held: only a SIGKILL can leave a token behind.
my @published;

sub fail {
  my ($code, $message) = @_;
  unlink @published;
  print STDERR "trellis heavy: $message\n";
  POSIX::_exit($code);
}

# The caller's environment. Through the stable launcher, which starts every
# command under `env -i`, it arrives as a v1: base64 blob of `env -0`;
# scripts/heavy.sh refuses a launcher route that did not carry one. Invoked
# directly, the process environment already is the caller's.
my %caller;
if (defined $ENV{TRELLIS_HEAVY_CALLER_ENV}) {
  my $blob = $ENV{TRELLIS_HEAVY_CALLER_ENV};
  $blob =~ s/^v1:// or fail($EX_CONFIG, 'unrecognised caller environment encoding from the launcher');
  for my $pair (split /\0/, MIME::Base64::decode_base64($blob)) {
    my ($key, $value) = split /=/, $pair, 2;
    $caller{$key} = $value if defined $value && length $key;
  }
} else {
  %caller = %ENV;
}
delete $caller{TRELLIS_HEAVY_CALLER_ENV};

my $test_mode = ($caller{TRELLIS_HEAVY_TEST} // '') eq '1';
sub test_knob { my $name = shift; return $test_mode ? $caller{$name} : undef; }

my $home = $ENV{TRELLIS_HOME} // '';
if ($home eq '') {
  length($ENV{HOME} // '') or fail($EX_CONFIG, 'HOME is required when TRELLIS_HOME is unset');
  $home = "$ENV{HOME}/.trellis";
}
my $config = "$home/config.json";
my $dir = "$home/locks/heavy";
my $override = test_knob('TRELLIS_HEAVY_DIR');
$dir = $override if defined $override && length $override;

my %POOL = (
  heavy => {key => 'heavy_slots',       default => 2, prefix => 'slot'},
  light => {key => 'heavy_light_slots', default => 4, prefix => 'light'},
);

# Slot counts per pool: heavy_slots (absent means 2) and heavy_light_slots
# (absent means 4), each a JSON integer >= 1. Re-read on every poll. Returns
# ({heavy => N, light => L}) or (undef, one-line reason).
sub read_slots {
  open(my $fh, '<', $config) or return (undef, "cannot read machine config $config: $!");
  my $text = do { local $/; <$fh> };
  close $fh;
  my $data = eval { JSON::PP->new->decode($text) };
  return (undef, "machine config is not a JSON object: $config") unless ref $data eq 'HASH';
  my %n;
  for my $p (qw(heavy light)) {
    my $key = $POOL{$p}{key};
    if (!exists $data->{$key}) {
      $n{$p} = $POOL{$p}{default};
      next;
    }
    my $encoded = JSON::PP->new->allow_nonref->canonical->encode($data->{$key});
    return (undef, "$key must be an integer >= 1 (found $encoded) in $config") unless $encoded =~ /^[1-9][0-9]{0,5}$/;
    $n{$p} = $encoded + 0;
  }
  return (\%n);
}

# The slot directory is private: mode 700, a real directory, owned by us.
sub prepare_dir {
  my $parent = $dir;
  $parent =~ s{/[^/]+/?$}{};
  for my $path ($parent, $dir) {
    next if $path eq '' || -e $path || -l $path;
    mkdir($path, 0700) or $!{EEXIST} or return "cannot create slot directory $path: $!";
  }
  my @st = lstat($dir);
  return "slot directory is missing: $dir" unless @st;
  return "slot directory must be a real directory, not a symlink: $dir" if -l _ || !-d _;
  return "slot directory must be owned by uid $<: $dir" unless $st[4] == $<;
  return sprintf('slot directory must have mode 700, found %03o: %s', $st[2] & 07777, $dir) if $st[2] & 077;
  return undef;
}

sub dir_id {
  my @st = stat($dir) or return undef;
  return "$st[0]:$st[1]";
}

sub slot_path { my ($p, $i) = @_; return "$dir/$POOL{$p}{prefix}-$i.lock"; }
sub info_path { my ($p, $i) = @_; return "$dir/$POOL{$p}{prefix}-$i.info"; }
sub token_path { my ($p, $i) = @_; return "$dir/$POOL{$p}{prefix}-$i.token"; }

# The holder's ownership token: written under the lock right after acquiring,
# removed while still holding just before release. Present means the holder
# has not released; nobody else can write one while the lock is held.
sub read_token {
  my ($p, $i) = @_;
  # A token is only a regular file of ours, mode 600, never reached through a
  # symlink; anything else is no token at all.
  sysopen(my $fh, token_path($p, $i), O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or return undef;
  my @st = stat($fh);
  unless (@st && -f _ && $st[4] == $< && ($st[2] & 07777) == 0600) {
    close $fh;
    return undef;
  }
  my $line = <$fh>;
  close $fh;
  return undef unless defined $line;
  chomp $line;
  return $line;
}

# Open (creating when absent) one slot file: O_NOFOLLOW, mode 600, never deleted.
sub open_slot {
  my ($p, $i) = @_;
  sysopen(my $fh, slot_path($p, $i), O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0600) or return undef;
  unless (-f $fh) { close $fh; return undef; }
  return $fh;
}

# Highest slot index present on disk, so retired slots stay visible.
sub max_slot_on_disk {
  my $p = shift;
  my $max = 0;
  opendir(my $dh, $dir) or return 0;
  for (readdir $dh) { $max = $1 if /^\Q$POOL{$p}{prefix}\E-([1-9][0-9]*)\.lock$/ && $1 > $max; }
  closedir $dh;
  return $max;
}

# The status probe: try LOCK_NB on a fresh description and release at once.
sub slot_is_held {
  my ($p, $i) = @_;
  return 0 unless -e slot_path($p, $i);
  my $fh = open_slot($p, $i) or return 0;
  my $held = !flock($fh, LOCK_EX | LOCK_NB);
  close $fh;
  return $held;
}

sub read_info {
  my ($p, $i) = @_;
  open(my $fh, '<', info_path($p, $i)) or return undef;
  my $line = <$fh>;
  close $fh;
  return undef unless defined $line;
  chomp $line;
  my @fields = split /\t/, $line, 4;
  return @fields == 4 ? \@fields : undef;
}

sub held_summary {
  my ($p, $n) = @_;
  my @held;
  my $max = max_slot_on_disk($p);
  $max = $n if $n > $max;
  for my $i (1 .. $max) {
    next unless slot_is_held($p, $i);
    my $info = read_info($p, $i);
    push @held, "$i=" . ($info ? "$info->[1]/$info->[0]" : 'unknown');
  }
  return @held ? join(' ', @held) : 'none';
}

# Bash %q-compatible quoting, so the info file's argv field round-trips through
# `eval "set -- $field"`.
sub shell_quote {
  my $s = shift;
  return "''" if $s eq '';
  return $s if $s =~ m{^[A-Za-z0-9_@%+=:,./-]+$};
  if ($s =~ /[\x00-\x1f\x7f]/) {
    (my $q = $s) =~ s/([\\'])/\\$1/g;
    $q =~ s/\t/\\t/g;
    $q =~ s/\n/\\n/g;
    $q =~ s/\r/\\r/g;
    $q =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02x', ord $1)/ge;
    return "\$'$q'";
  }
  (my $q = $s) =~ s/'/'\\''/g;
  return "'$q'";
}

sub trace {
  my $file = test_knob('TRELLIS_HEAVY_TEST_TRACE');
  return unless defined $file && length $file;
  open(my $fh, '>>', $file) or return;
  print {$fh} "@_\n";
  close $fh;
}

my $mode = shift @ARGV // '';

if ($mode eq 'check') {
  my ($n, $why) = read_slots();
  fail($EX_CONFIG, $why) unless $n;
  my $problem = prepare_dir();
  fail($EX_CONFIG, $problem) if $problem;
  print "trellis heavy: ok (heavy_slots=$n->{heavy}, heavy_light_slots=$n->{light}, slots in $dir)\n";
  exit 0;
}

if ($mode eq 'status') {
  my ($n, $why) = read_slots();
  fail($EX_CONFIG, $why) unless $n;
  my $problem = prepare_dir();
  fail($EX_CONFIG, $problem) if $problem;
  print "heavy_slots=$n->{heavy} heavy_light_slots=$n->{light} dir=$dir\n";
  for my $p (qw(heavy light)) {
    my $label = $POOL{$p}{prefix};
    my $max = max_slot_on_disk($p);
    $max = $n->{$p} if $n->{$p} > $max;
    for my $i (1 .. $max) {
      my $retired = $i > $n->{$p} ? ' (retired)' : '';
      if (!slot_is_held($p, $i)) {
        print "$label $i: free$retired\n";
        next;
      }
      my $info = read_info($p, $i);
      if ($info) {
        print "$label $i: held$retired lane=$info->[1] pid=$info->[0] since=$info->[2] argv=$info->[3]\n";
      } else {
        print "$label $i: held$retired unknown\n";
      }
    }
  }
  exit 0;
}

$mode eq 'run' or fail($EX_USAGE, "unknown supervisor mode: $mode");
my $pool = shift @ARGV // '';
$POOL{$pool} or fail($EX_USAGE, "unknown pool: $pool");
my $lane = shift @ARGV;
my $timeout = shift @ARGV;
my @command = @ARGV;
@command or fail($EX_USAGE, 'a command is required after --');

my $kill_after = $caller{TRELLIS_HEAVY_KILL_AFTER} // 10;
$kill_after =~ /^(?:[0-9]+(?:\.[0-9]+)?)$/ or fail($EX_USAGE, "TRELLIS_HEAVY_KILL_AFTER must be a number of seconds: $kill_after");
my $poll = test_knob('TRELLIS_HEAVY_TEST_POLL') // 5;
my $heartbeat = test_knob('TRELLIS_HEAVY_TEST_HEARTBEAT') // 60;
my $light_warn = test_knob('TRELLIS_HEAVY_LIGHT_WARN') // 120;
$light_warn =~ /^(?:[0-9]+(?:\.[0-9]+)?)$/ or fail($EX_USAGE, "TRELLIS_HEAVY_LIGHT_WARN must be a number of seconds: $light_warn");

# Signals are recorded, never acted on inside the handler. The first one
# decides the exit status. A no-op CHLD handler makes a sleep end early when
# the workload's leader exits, without reaping it.
my $pending;
for my $name (keys %SIGNUM) {
  $SIG{$name} = sub { $pending //= $name; };
}
$SIG{CHLD} = sub { };

my $slot;
sub exit_for_signal {
  unlink token_path($pool, $slot), info_path($pool, $slot) if defined $slot;
  POSIX::_exit(128 + $SIGNUM{$pending});
}

# Nested call: verified only when every check holds. A spoofed or stale marker
# fails, and the call then acquires a slot normally. The pool comes from the
# marker, never from this call's own --light: a holder of either pool counts.
sub verified_nested_fd {
  my ($fd, $slot, $id, $mpool) = @caller{qw(TRELLIS_HEAVY_FD TRELLIS_HEAVY_SLOT TRELLIS_HEAVY_DIR_ID TRELLIS_HEAVY_POOL)};
  return undef unless defined $mpool && $POOL{$mpool};
  return undef unless defined $fd && $fd =~ /^[0-9]+$/;
  return undef unless defined $slot && $slot =~ /^[1-9][0-9]*$/;
  return undef unless defined $id && $id =~ /^[0-9]+:[0-9]+$/;
  return undef unless (dir_id() // '') eq $id;
  my @file = lstat(slot_path($mpool, $slot));
  return undef unless @file && -f _;
  # Inspect a dup, never the caller's descriptor itself: every rejection below
  # closes only the dup, and the inherited descriptor stays as it was.
  open(my $dup, '+<&', $fd) or return undef;
  my @held = stat($dup);
  return undef unless @held && $held[0] == $file[0] && $held[1] == $file[1];
  # Ownership must be continuous, not merely current. The marker's token must
  # match the holder's token file before the descriptor is touched at all...
  my $token = $caller{TRELLIS_HEAVY_TOKEN};
  return undef unless defined $token && $token =~ /^[0-9a-f]{32}$/;
  return undef unless (read_token($mpool, $slot) // '') eq $token;
  if ((test_knob('TRELLIS_HEAVY_TEST_PAUSE') // '') eq 'verify-before-flock') {
    print STDERR "trellis heavy: test pause verify-before-flock\n";
    Time::HiRes::sleep(1);
  }
  # ...then one flock(2) on the inherited description. Any failure acquires
  # nothing and rejects: another description holds the slot, or the call
  # failed. Success means this description holds the lock now, but on its own
  # not that it held it before: had the holder released since the token was
  # read, this flock has just taken the lock.
  return undef unless flock($dup, LOCK_EX | LOCK_NB);
  # A holder removes its token before it releases, and nobody can write one
  # while this description holds the lock. So an unchanged token proves no
  # release happened in between. A changed or missing one means the lock was
  # taken just now: give it back and reject.
  if ((read_token($mpool, $slot) // '') ne $token) {
    flock($dup, LOCK_UN);
    return undef;
  }
  return 1;
}

my $problem = prepare_dir();
fail($EX_CONFIG, $problem) if $problem;

my $nested = verified_nested_fd();
my ($lock, %child_env);
%child_env = %caller;

my $block = POSIX::SigSet->new(SIGINT, SIGTERM, SIGHUP);
if (!$nested) {
  my $waited_since = Time::HiRes::time();
  my $last_heartbeat = $waited_since;
  while (1) {
    exit_for_signal() if $pending;
    my ($n, $why) = read_slots();
    fail($EX_CONFIG, $why) unless $n;
    POSIX::sigprocmask(SIG_BLOCK, $block);
    for my $i (1 .. $n->{$pool}) {
      my $fh = open_slot($pool, $i) or next;
      if (flock($fh, LOCK_EX | LOCK_NB)) {
        $lock = $fh;
        $slot = $i;
        last;
      }
      close $fh;
    }
    if ($lock) {
      if ((test_knob('TRELLIS_HEAVY_TEST_PAUSE') // '') eq 'after-acquire') {
        print STDERR "trellis heavy: test pause after-acquire slot=$slot\n";
        Time::HiRes::sleep(2);
      }
      # Cancellation check before unblocking: a signal that arrived during
      # acquisition is still pending here, so exit without forking. The
      # kernel drops the lock with the descriptor.
      my $set = POSIX::SigSet->new;
      POSIX::sigpending($set);
      for my $name (qw(INT TERM HUP)) {
        POSIX::_exit(128 + $SIGNUM{$name}) if $set->ismember($SIGNUM{$name});
      }
      last;    # still blocked: they stay blocked until the launch is armed
    }
    POSIX::sigprocmask(SIG_UNBLOCK, $block);
    exit_for_signal() if $pending;
    my $now = Time::HiRes::time();
    if ($now - $last_heartbeat >= $heartbeat) {
      $last_heartbeat = $now;
      printf STDERR "trellis heavy: waiting %ds for a %s slot (%s=%d); held: %s\n",
        $now - $waited_since, $pool, $POOL{$pool}{key}, $n->{$pool}, held_summary($pool, $n->{$pool});
    }
    Time::HiRes::sleep($poll);
  }

  # Hand the lock to the workload on a high descriptor with FD_CLOEXEC
  # cleared explicitly; perl's $^F is not relied on.
  my $high = fcntl($lock, F_DUPFD, 64);
  defined $high or fail($EX_UNAVAILABLE, "could not duplicate the slot descriptor: $!");
  open(my $held, '+<&=', $high) or fail($EX_UNAVAILABLE, "could not adopt the slot descriptor: $!");
  fcntl($held, F_SETFD, 0) or fail($EX_UNAVAILABLE, "could not clear close-on-exec on the slot descriptor: $!");
  close $lock;
  $lock = $held;
  $child_env{TRELLIS_HEAVY_FD} = $high;
  $child_env{TRELLIS_HEAVY_SLOT} = $slot;
  $child_env{TRELLIS_HEAVY_DIR_ID} = dir_id();
  $child_env{TRELLIS_HEAVY_POOL} = $pool;

  # The ownership token nested calls must present (see verified_nested_fd).
  my $token = '';
  if (open(my $rand, '<:raw', '/dev/urandom')) {
    read($rand, my $bytes, 16);
    close $rand;
    $token = unpack('H*', $bytes // '');
  }
  length($token) == 32 or fail($EX_UNAVAILABLE, 'could not read /dev/urandom for the slot token');
  my $token_tmp = token_path($pool, $slot) . ".tmp.$$";
  sysopen(my $tfh, $token_tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
    or fail($EX_UNAVAILABLE, "could not write the slot token: $!");
  # Test hook: a token write that fails the way a full disk would.
  close $tfh if (test_knob('TRELLIS_HEAVY_TEST_FAIL') // '') eq 'token-write';
  my $written = do { no warnings 'closed'; print {$tfh} "$token\n" };
  my $closed = close $tfh;
  unless ($written && $closed) {
    my $why = $!;
    unlink $token_tmp;
    fail($EX_UNAVAILABLE, "could not write the slot token: $why");
  }
  unless (rename($token_tmp, token_path($pool, $slot))) {
    my $why = $!;
    unlink $token_tmp;
    fail($EX_UNAVAILABLE, "could not publish the slot token: $why");
  }
  push @published, token_path($pool, $slot);
  $child_env{TRELLIS_HEAVY_TOKEN} = $token;

  # pid, lane, ISO-8601 UTC, %q argv. Written under the lock, atomically.
  my $tmp = info_path($pool, $slot) . ".tmp.$$";
  if (sysopen(my $info, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)) {
    print {$info} join("\t", $$, $lane, POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
      join(' ', map { shell_quote($_) } @command)), "\n";
    close $info;
    if (rename($tmp, info_path($pool, $slot))) {
      push @published, info_path($pool, $slot);
    } else {
      unlink $tmp;
    }
  }
  # Test hook: a failure once both the token and the info file are published.
  fail($EX_UNAVAILABLE, 'test failure after publishing the slot token')
    if (test_knob('TRELLIS_HEAVY_TEST_FAIL') // '') eq 'after-publish';
}

# INT, TERM and HUP stay blocked from here, across fork and group setup, until
# the launch is armed. A signal meant for the supervisor's group (a terminal
# ^C, say) can then never reach a child still standing in that group with its
# default disposition; it stays pending and is handled as a cancellation.
POSIX::sigprocmask(SIG_BLOCK, $block);
exit_for_signal() if $pending;

# Launch: the child joins its own group (outer calls only), reports through a
# sync pipe, and waits for a go byte, so forwarding is armed before exec.
pipe(my $sync_r, my $sync_w) or fail($EX_UNAVAILABLE, "pipe: $!");
pipe(my $go_r, my $go_w) or fail($EX_UNAVAILABLE, "pipe: $!");
my $pid = fork();
defined $pid or fail($EX_UNAVAILABLE, "fork: $!");
trace('fork') if $pid;
if ($pid == 0) {
  $SIG{$_} = 'DEFAULT' for (keys %SIGNUM, 'CHLD');
  close $sync_r;
  close $go_w;
  if ((test_knob('TRELLIS_HEAVY_TEST_PAUSE') // '') eq 'after-fork') {
    print STDERR "trellis heavy: test pause after-fork child=$$\n";
    Time::HiRes::sleep(1);
  }
  setpgrp(0, 0) unless $nested;
  syswrite($sync_w, 's', 1);
  close $sync_w;
  my $byte = '';
  my $got = sysread($go_r, $byte, 1);
  POSIX::_exit(125) unless $got && $byte eq 'g';
  close $go_r;
  trace('exec');
  POSIX::sigprocmask(SIG_UNBLOCK, $block);    # the workload starts unmasked
  %ENV = %child_env;
  { no warnings 'exec'; exec { $command[0] } @command; }
  print STDERR "trellis heavy: cannot run $command[0]: $!\n";
  POSIX::_exit($!{ENOENT} ? 127 : 126);
}
close $sync_w;
close $go_r;
my $byte = '';
while (1) {
  my $got = sysread($sync_r, $byte, 1);
  last if defined $got;
  last unless $!{EINTR};
}
close $sync_r;
if (!$nested && ($byte ne 's' || getpgrp($pid) != $pid)) {
  kill 'KILL', $pid;
  waitpid($pid, 0);
  fail($EX_UNAVAILABLE, 'could not place the workload in its own process group');
}

# Cancellation check, still blocked: anything that arrived since acquisition
# is pending here. A cancelled child reads EOF and exits 125 without exec, and
# the supervisor still exits 128+signal.
{
  my $set = POSIX::SigSet->new;
  POSIX::sigpending($set);
  for my $name (qw(INT TERM HUP)) {
    $pending //= $name if $set->ismember($SIGNUM{$name});
  }
}
my $started = Time::HiRes::time();
my $deadline = $timeout ? $started + $timeout : undef;
if ($pending) {
  close $go_w;
} else {
  syswrite($go_w, 'g', 1);
  close $go_w;
}
# Armed: from here signals and the timeout tear down the workload.
POSIX::sigprocmask(SIG_UNBLOCK, $block);

my ($teardown, $term_at, $killed, $status);
# Advisory only, and only from a supervisor that holds a light slot: a verified
# nested --light call holds none.
my $warn_at = ($pool eq 'light' && !$nested) ? $started + $light_warn : undef;

sub signal_workload {
  my $sig = shift;
  if ($nested) {
    kill $sig, $pid;    # direct child only; the outer supervisor owns the group
  } else {
    trace("signal $sig group");
    kill $sig, -$pid;
  }
}

# One `ps` row set: the leader's state and how many other processes share its
# group. Filtered on the pgid column; `-g` means session on Linux procps.
# Returns () when the probe cannot be trusted: ps failed, or its output lacks
# the leader, which is never reaped early and so must be listed. Unknown is
# never read as empty.
sub scan_group {
  my ($leader, $others) = (undef, 0);
  my @rows = `ps -A -o pid=,pgid=,stat=`;
  return () if $? != 0;
  for my $row (@rows) {
    my ($p, $g, $s) = split ' ', $row;
    next unless defined $s && $p =~ /^[0-9]+$/ && $g =~ /^[0-9]+$/;
    if ($p == $pid) {
      $leader = $s;
    } elsif ($g == $pid) {
      $others++;
    }
  }
  return () unless defined $leader;
  return ($leader, $others);
}

my $leader_exited = 0;
my $probe_warned = 0;
while (1) {
  my $now = Time::HiRes::time();
  if (!$teardown && $pending) {
    $teardown = 'signal';
  } elsif (!$teardown && $deadline && $now >= $deadline) {
    $teardown = 'timeout';
  }
  if ($teardown && !defined $term_at) {
    $term_at = $now;
    signal_workload('TERM');
  }
  if (defined $term_at && !$killed && $now - $term_at >= $kill_after) {
    $killed = 1;
    signal_workload('KILL');
  }
  if (defined $warn_at && $now >= $warn_at) {
    printf STDERR "trellis heavy: light run exceeded %ds; use the heavy pool for long runs\n", $light_warn;
    $warn_at = undef;
  }

  if ($nested) {
    if (waitpid($pid, WNOHANG) == $pid) {
      $status = $?;
      last;
    }
  } else {
    # The leader is never reaped early: an unreaped zombie keeps its pid, and
    # so the group ID, allocated while group signals may still be sent.
    my ($leader, $others) = scan_group();
    if (!defined $leader) {
      # Keep the slot and keep supervising (escalation still runs) until the
      # group is positively seen to be empty.
      trace('probe-unknown');
      print STDERR "trellis heavy: cannot read the workload's process group (ps failed or incomplete); keeping the slot\n"
        unless $probe_warned++;
    } elsif (!$leader_exited && $leader =~ /Z/) {
      $leader_exited = 1;
      trace('leader-zombie');
    }
    if (defined $leader && $leader_exited && $others == 0) {
      trace('group-empty');
      waitpid($pid, 0);
      $status = $?;
      trace('reap');
      last;
    }
  }

  my $nap = 0.5;
  $nap = $deadline - $now if !$teardown && $deadline && $deadline - $now < $nap;
  $nap = $term_at + $kill_after - $now if defined $term_at && !$killed && $term_at + $kill_after - $now < $nap;
  $nap = $warn_at - $now if defined $warn_at && $warn_at - $now < $nap;
  Time::HiRes::sleep($nap > 0.01 ? $nap : 0.01);
}

exit_for_signal() if ($teardown // '') eq 'signal';
unlink token_path($pool, $slot), info_path($pool, $slot) if defined $slot;
POSIX::_exit($EX_TIMEOUT) if ($teardown // '') eq 'timeout';
POSIX::_exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
