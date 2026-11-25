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
# borrow from each other. Heavy slot 0 is reserved for lane process-gate;
# an opt-in overflow gate borrows one actual ordinary slot (1..heavy_slots).
# A short mutex serializes admissions; it is never handed to the workload. The
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
use POSIX qw(SIGINT SIGTERM SIGHUP SIGQUIT SIG_BLOCK SIG_UNBLOCK WNOHANG);
use Cwd ();
use JSON::PP ();
use MIME::Base64 ();
use Time::HiRes ();

my $EX_USAGE       = 2;
my $EX_UNAVAILABLE = 5;
my $EX_CONFIG      = 78;
my $EX_TIMEOUT     = 124;
my %SIGNUM         = (INT => SIGINT, TERM => SIGTERM, HUP => SIGHUP, QUIT => SIGQUIT);

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
  overflow => {prefix => 'gate-overflow'},
  admission => {prefix => 'gate-admission'},
  repo => {prefix => 'gate-repo'},
);

# Slot counts per pool: heavy_slots (absent means 2) and heavy_light_slots
# (absent means 4), each a JSON integer >= 1. Re-read on every poll. Returns
# ({heavy => N, light => L}) or (undef, one-line reason).
sub read_slots {
  # Only the embedded launcher metadata program defines this lexical cache
  # accessor. The standalone supervisor still reads afresh on every poll.
  return launcher_metadata_config() if defined &launcher_metadata_config;
  sysopen(my $fh, $config, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    or return (undef, "cannot read machine config $config: $!");
  my $text = -f $fh ? _pp_slurp($fh, 1048576) : undef;
  close $fh;
  return (undef, "cannot read regular machine config $config") unless defined $text;
  return slot_counts($text);
}

sub slot_counts {
  my ($text) = @_;
  my $data = eval { JSON::PP->new->utf8->allow_bignum->decode($text) };
  return (undef, "machine config is not a JSON object: $config") unless ref $data eq 'HASH';
  my %n;
  for my $p (qw(heavy light)) {
    my $key = $POOL{$p}{key};
    if (!exists $data->{$key}) {
      $n{$p} = $POOL{$p}{default};
      next;
    }
    my $encoded = JSON::PP->new->allow_nonref->allow_bignum->canonical->encode($data->{$key});
    return (undef, "$key must be an integer >= 1 (found $encoded) in $config") unless $encoded =~ /\A[1-9][0-9]{0,5}\z/;
    $n{$p} = $encoded + 0;
  }
  $n{gate} = 1;
  if (exists $data->{process_gate_slots}) {
    my $raw = $data->{process_gate_slots};
    my $encoded = JSON::PP->new->allow_nonref->allow_bignum->encode($raw);
    if (!ref($raw) && $encoded =~ /\A[12]\z/) {
      $n{gate} = 0 + $encoded;
    } else {
      $n{gate_warning} = 'process_gate_slots must be an integer 1 or 2; using 1';
    }
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
  my @st = stat($fh);
  # Existing ordinary/light permits may be pre-created in the private
  # directory. Only the new gate-specific locks require mode 0600.
  unless (@st && -f _ && $st[4] == $< &&
      ($p eq 'heavy' || $p eq 'light' || ($st[2] & 07777) == 0600)) {
    close $fh;
    return undef;
  }
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
  my $held = !flock($fh, LOCK_EX | LOCK_NB) && ($!{EAGAIN} || $!{EWOULDBLOCK});
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
  for my $i (($p eq 'heavy' ? (0) : ()), 1 .. $max) {
    next unless slot_is_held($p, $i);
    my $info = read_info($p, $i);
    push @held, "$i=" . ($info ? "$info->[1]/$info->[0]" : 'unknown');
  }
  return @held ? join(' ', @held) : 'none';
}

# Gate metadata never substitutes for a live, token-matched permit. Primary
# and overflow use separate records; overflow's token lives on its borrowed
# ordinary slot. Readers may get an unknown result while a holder exits.
sub monotime { return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); }
sub gate_path { return "$dir/gate-$_[0].json"; }

sub read_gate_record {
  my $kind = shift;
  sysopen(my $fh, gate_path($kind), O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or return undef;
  my @st = stat($fh);
  return undef unless @st && -f _ && $st[4] == $< && ($st[2] & 07777) == 0600 && $st[7] <= 32768;
  my $text = '';
  return undef unless defined(sysread($fh, $text, 32769)) && length($text) <= 32768;
  my $record = eval { JSON::PP->new->utf8->decode($text) };
  return ref($record) eq 'HASH' ? $record : undef;
}

sub write_gate_record {
  my ($kind, $record) = @_;
  my $path = gate_path($kind);
  my $tmp = "$path.tmp.$$";
  my $bytes = JSON::PP->new->utf8->encode($record);
  return 0 if length($bytes) > 32768;
  sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or return 0;
  my $written = print {$fh} $bytes;
  my $closed = close $fh;
  return 1 if $written && $closed && rename($tmp, $path);
  unlink $tmp;
  return 0;
}

sub try_slot {
  my $fh = open_slot(@_) or return (undef, 'invalid');
  return ($fh, undef) if flock($fh, LOCK_EX | LOCK_NB);
  return (undef, ($!{EAGAIN} || $!{EWOULDBLOCK}) ? 'held' : 'invalid');
}

sub gate_live {
  my ($kind) = @_;
  my ($p, $i) = $kind eq 'primary' ? ('heavy', 0) : ('overflow', 1);
  # Status must not claim a failed probe means a vacant position. Missing
  # paths are free, but existing unreadable or corrupt lock files are unknown.
  if (!lstat(slot_path($p, $i))) { return $!{ENOENT} ? undef : {}; }
  my ($free, $state) = try_slot($p, $i);
  return undef if $free;
  return {} unless $state eq 'held';
  my $r = read_gate_record($kind) or return {};
  my ($slot, $token, $repo, $since, $worktree, $paths) = @$r{qw(slot token repo since worktree paths)};
  return {} unless defined $slot && ($kind eq 'primary' ? $slot eq '0' : $slot =~ /\A[1-9][0-9]{0,5}\z/);
  return {} unless defined $token && $token =~ /\A[0-9a-f]{32}\z/ && (read_token('heavy', $slot) // '') eq $token;
  return {} if $kind eq 'overflow' && !slot_is_held('heavy', $slot);
  # An unknown identity can hold the primary exclusively, but never overlap.
  return $r unless defined $repo;
  return {} unless $repo =~ /\A[0-9]+:[0-9]+\z/ && slot_is_held('repo', $repo)
    && defined $since && $since =~ /\A[0-9]+(?:\.[0-9]+)?\z/
    && defined $worktree && $worktree =~ m{\A/} && (!defined $paths || ref($paths) eq 'ARRAY');
  return $r;
}

sub gate_status {
  my ($n) = @_;
  my $primary = gate_live('primary');
  my $overflow = gate_live('overflow');
  my $last = read_gate_record('last') // {};
  my $reason = $last->{reason} // 'none';
  $reason = 'none' unless $reason =~ /\A(?:same-repo|ordinary-full|load|memory|swap|disk|probe-unknown|stagger|config|gate-full|none)\z/;
  my $effective = 1;
  my $sole = $primary // $overflow;
  if ($n->{gate} == 2 && (!$overflow || (defined $overflow->{slot} && $overflow->{slot} <= $n->{heavy}))) {
    if (($primary && $overflow && $primary->{repo} && $overflow->{repo}) ||
        ($sole && $sole->{repo} && ($last->{token} // '') eq $sole->{token}
         && $reason eq 'none' && ($last->{at} // '') =~ /\A[0-9]+(?:\.[0-9]+)?\z/
         && monotime() - $last->{at} >= 0 && monotime() - $last->{at} <= 5)) {
      $effective = 2;
    }
  }
  print "process_gate_slots=$n->{gate} effective_process_gate_slots=$effective last-denial=$reason\n";
  for my $row (['primary', $primary], ['overflow', $overflow]) {
    my ($kind, $r) = @$row;
    my $label = "process-gate $kind";
    if (!$r) {
      print "$label: free\n";
    } elsif (!defined $r->{slot}) {
      print "$label: held (ownership unverified)\n";
    } else {
      my $info = read_info('heavy', $r->{slot});
      my $borrow = $kind eq 'overflow' ? " borrowed=slot-$r->{slot}" : '';
      my $drain = $kind eq 'overflow' && $effective == 1 ? ' (draining)' : '';
      my $where = defined $r->{worktree} ? ' worktree=' . shell_quote($r->{worktree}) : '';
      print "$label: held$drain$borrow", ($info ? " pid=$info->[0]" : ''), "$where\n";
    }
  }
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
  for my $p (qw(admission overflow)) {
    my $fh = open_slot($p, 1) or fail($EX_CONFIG, "cannot open $p permit in $dir");
  }
  my $primary = open_slot('heavy', 0) or fail($EX_CONFIG, "cannot open primary permit in $dir");
  print STDERR "trellis heavy: $n->{gate_warning}\n" if $n->{gate_warning};
  print "trellis heavy: ok (heavy_slots=$n->{heavy}, heavy_light_slots=$n->{light}, process_gate_slots=$n->{gate}, process_gate_protocol=2, slots in $dir)\n";
  exit 0;
}

if ($mode eq 'status') {
  my ($n, $why) = read_slots();
  fail($EX_CONFIG, $why) unless $n;
  my $problem = prepare_dir();
  fail($EX_CONFIG, $problem) if $problem;
  print STDERR "trellis heavy: $n->{gate_warning}\n" if $n->{gate_warning};
  print "heavy_slots=$n->{heavy} heavy_light_slots=$n->{light} dir=$dir\n";
  gate_status($n);
  for my $p (qw(heavy light)) {
    my $label = $POOL{$p}{prefix};
    my $max = max_slot_on_disk($p);
    $max = $n->{$p} if $n->{$p} > $max;
    for my $i (($p eq 'heavy' ? (0) : ()), 1 .. $max) {
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

my $pressure_reap_pid;

sub _pp_bounded {
  my ($cap, $work) = @_;
  my $start = eval { monotime() };
  return undef unless defined $start;
  my $end = $start + 2;
  local $SIG{CHLD} = sub {};
  if (defined $pressure_reap_pid) {
    my $r = waitpid($pressure_reap_pid, POSIX::WNOHANG());
    return undef unless $r == $pressure_reap_pid || ($r == -1 && $!{ECHILD});
    undef $pressure_reap_pid;
  }
  pipe(my $rd, my $wr) or return undef;
  my $pid = fork();
  return undef unless defined $pid;
  if ($pid == 0) {
    close $rd;
    $SIG{$_} = 'DEFAULT' for qw(CHLD PIPE INT TERM HUP QUIT);
    POSIX::setpgid(0, 0) or POSIX::_exit(1);
    open(STDIN, '<', '/dev/null') && open(STDERR, '>', '/dev/null')
      && open(STDOUT, '>&', $wr) && binmode(STDOUT, ':raw') or POSIX::_exit(1);
    close $wr;
    # No caller PATH, locale, Git routing, or dynamic-loader overrides.
    local %ENV = (PATH => '/usr/bin:/bin', LC_ALL => 'C');
    my $out = eval { $work->() };
    POSIX::_exit(1) unless defined $out && length($out) <= $cap;
    my $n = syswrite(STDOUT, $out);
    POSIX::_exit(defined $n && $n == length($out) ? 0 : 1);
  }
  close $wr;
  # Both sides set the group so timeout cleanup can also signal descendants.
  POSIX::setpgid($pid, $pid);
  my $fds = '';
  vec($fds, fileno($rd), 1) = 1;
  my $out = '';
  my $eof = 0;
  while ((my $left = $end - monotime()) > 0) {
    if ($eof) {
      my $r = waitpid($pid, POSIX::WNOHANG());
      if ($r == $pid) {
        return $? == 0 && monotime() <= $end ? $out : undef;
      }
      return undef if $r == -1 && !$!{EINTR};  # no longer ours to signal
      select(undef, undef, undef, $left < 0.005 ? $left : 0.005);
      next;
    }
    my $ready = $fds;
    my $r = select($ready, undef, undef, $left);
    next if $r == -1 && $!{EINTR};
    last unless $r > 0;
    my $n = sysread($rd, my $chunk, 8192);
    next if !defined $n && $!{EINTR};
    last unless defined $n;
    $out .= $chunk;
    last if length($out) > $cap;
    $eof = 1 unless $n;
  }
  # Do not block on reap: a volume probe can be stuck in uninterruptible I/O.
  # Leave at most one killed probe outstanding, and try to reap on the next call.
  # The direct child has not yet been reaped, so its PID cannot be reused here.
  kill 'KILL', $pid, -$pid;
  close $rd;
  my $r = waitpid($pid, POSIX::WNOHANG());
  $pressure_reap_pid = $pid unless $r == $pid || ($r == -1 && $!{ECHILD});
  return undef;
}

# Worker-only I/O; the parent enforces the wall deadline even for open/stat/close.
sub _pp_slurp {
  my ($fh, $cap) = @_;
  my $out = '';
  while (1) {
    my $n = sysread($fh, my $chunk, 8192);
    return undef unless defined $n;
    return $out unless $n;
    $out .= $chunk;
    return undef if length($out) > $cap;
  }
}

sub _pp_exec {
  my ($cap, $exe, @args) = @_;
  my $pid = open(my $fh, '-|');
  return undef unless defined $pid;
  if ($pid == 0) {
    exec {$exe} $exe, @args or POSIX::_exit(127);
  }
  my $out = _pp_slurp($fh, $cap);
  return close($fh) ? $out : undef;
}

sub _pp_file {
  my ($path, $cap) = @_;
  sysopen(my $fh, $path, Fcntl::O_RDONLY() | Fcntl::O_NOFOLLOW() | Fcntl::O_NONBLOCK())
    or return undef;
  return undef unless -f $fh;
  my $out = _pp_slurp($fh, $cap);
  return close($fh) ? $out : undef;
}

sub _pp_abspath {
  my ($p) = @_;
  return defined $p && !ref $p && length($p) <= 4096 && $p =~ m{\A/[^\x00-\x1f\x7f]*\z};
}

# Strict unsigned integer text. Preserve full counters as strings (fingerprint).
sub _pp_uint {
  my ($s) = @_;
  return defined $s && $s =~ /\A(?:0|[1-9][0-9]{0,19})\z/
    && (length($s) < 20 || $s le '18446744073709551615') ? $s : undef;
}

sub _pp_knob {
  my ($path, $unlimited) = @_;
  my $text = _pp_file($path, 128);
  return undef unless defined $text && $text =~ s/\n\z//;
  return 'max' if defined $unlimited && $text eq $unlimited;
  return _pp_uint($text);
}

sub _pp_mem_low {
  my ($available, $total) = @_;
  return $available < 8 * 1024**3 || $available < $total / 4;
}

sub _pp_swap_high {
  my ($used, $total) = @_;
  return $total == 0 ? $used != 0 : $used >= $total * 0.8;
}

sub _pp_fields {
  my ($text, $pattern, @keys) = @_;
  return undef unless defined $text && $text =~ /\n\z/;
  my %wanted = map { $_ => 1 } @keys;
  my %out;
  for my $line (split /\n/, $text) {
    next unless $line =~ /\A([A-Za-z_][A-Za-z_0-9]*)(?=[: \t]|\z)/ && $wanted{$1};
    return undef unless $line =~ $pattern;
    my ($key, $value) = ($1, $2);
    return undef if exists $out{$key} || !defined _pp_uint($value);
    $out{$key} = $value;
  }
  return keys(%out) == @keys ? \%out : undef;
}

sub _pp_cpu_ranges {
  my ($text) = @_;
  return undef unless defined $text;
  my @ranges;
  my $prev = -1;
  for my $r (split /,/, $text, -1) {
    return undef unless $r =~ /\A(0|[1-9][0-9]{0,5})(?:-(0|[1-9][0-9]{0,5}))?\z/;
    my ($lo, $hi) = ($1, $2 // $1);
    return undef if $lo <= $prev || $hi < $lo;
    push @ranges, [$lo, $hi];
    $prev = $hi;
  }
  return @ranges ? \@ranges : undef;
}

sub _pp_linux_cpus {
  my $status = _pp_file('/proc/self/status', 131072);
  my $online = _pp_file('/sys/devices/system/cpu/online', 32768);
  return undef unless defined $status && defined $online && $online =~ s/\n\z//;
  my @allowed = $status =~ /^Cpus_allowed_list:[ \t]+([^\n]*)$/mg;
  return undef unless @allowed == 1;
  my ($a, $b) = (_pp_cpu_ranges($allowed[0]), _pp_cpu_ranges($online));
  return undef unless $a && $b;
  my ($i, $j, $n) = (0, 0, 0);
  while ($i < @$a && $j < @$b) {
    my ($al, $ah) = @{$a->[$i]};
    my ($bl, $bh) = @{$b->[$j]};
    my $lo = $al > $bl ? $al : $bl;
    my $hi = $ah < $bh ? $ah : $bh;
    $n += $hi - $lo + 1 if $hi >= $lo;
    $ah < $bh ? ++$i : ++$j;
  }
  return $n || undef;
}

sub _pp_cgroup_path {
  my ($path) = @_;
  return _pp_abspath($path) && ($path eq '/' || $path !~ m{//|/(?:\.|\.\.)(?:/|\z)|/\z});
}

# Require a visible hierarchy root. A bind/subtree mount or private namespace
# can hide finite ancestor limits; don't assume its visible root is unlimited.
sub _pp_cgroup_mounts {
  my ($mi) = @_;
  return undef unless defined $mi && $mi =~ /\n\z/;
  my %mount;
  for my $line (split /\n/, $mi) {
    my ($pre, $post) = split / - /, $line, 2;
    return undef unless defined $post;
    my ($type, $source, $opts) = split / /, $post;
    next unless $type eq 'cgroup' || $type eq 'cgroup2';
    my (undef, undef, undef, $root, $dir) = split / /, $pre;
    next unless defined $root && $root eq '/' && defined $dir && defined $opts;
    next if $dir =~ /\\(?!040|011|012|134)/;
    $dir =~ s/\\(040|011|012|134)/chr(oct($1))/eg;
    next unless _pp_cgroup_path($dir);
    $dir = '' if $dir eq '/';
    if ($type eq 'cgroup2') {
      next unless defined _pp_file("$dir/cgroup.controllers", 4096);
      next if lstat("$dir/cgroup.events") || !$!{ENOENT};
      $mount{v2} //= $dir;
    } else {
      next unless -f "$dir/release_agent";
      for my $c (grep { $_ eq 'cpu' || $_ eq 'memory' } split /,/, $opts) {
        $mount{$c} //= $dir;
      }
    }
  }
  return \%mount;
}

sub _pp_cgroup_members {
  my ($text) = @_;
  return undef unless defined $text && ($text eq '' || $text =~ /\n\z/);
  my %members;
  for my $line (split /\n/, $text) {
    return undef unless $line =~ /\A(0|[1-9][0-9]{0,9}):([^:]*):(.+)\z/;
    my ($id, $controllers, $path) = ($1, $2, $3);
    return undef if ($id eq '0') != ($controllers eq '');
    my @relevant = $id eq '0' ? ('v2') : grep { $_ eq 'cpu' || $_ eq 'memory' } split /,/, $controllers;
    for my $c (@relevant) {
      return undef unless _pp_cgroup_path($path) && !exists $members{$c};
      $members{$c} = $path;
    }
  }
  return \%members;
}

sub _pp_cgroup_cpu {
  my ($d, $v2) = @_;
  my ($q, $p);
  if ($v2) {
    my $text = _pp_file("$d/cpu.max", 128);
    return undef unless defined $text && $text =~ /\A(max|[1-9][0-9]*) ([1-9][0-9]*)\n\z/;
    ($q, $p) = ($1, $2);
    $q = _pp_uint($q) if $q ne 'max';
    $p = _pp_uint($p);
  } else {
    $q = _pp_knob("$d/cpu.cfs_quota_us", '-1');
    $p = _pp_knob("$d/cpu.cfs_period_us");
  }
  return undef unless defined $p && $p > 0 && defined $q && ($q eq 'max' || $q > 0);
  return $q eq 'max' ? 'max' : $q / $p;
}

# Report per-ancestor vetoes rather than interpreting local usage as leaf-only.
sub _pp_cgroup_mem {
  my ($d, $v2, $ram, $swap) = @_;
  my $limit = _pp_knob("$d/" . ($v2 ? 'memory.max' : 'memory.limit_in_bytes'), $v2 ? 'max' : undef);
  my $used = _pp_knob("$d/" . ($v2 ? 'memory.current' : 'memory.usage_in_bytes'));
  return 'probe-unknown' unless defined $limit && defined $used;
  my @limits = ($limit);
  if ($v2) {
    my $high = _pp_knob("$d/memory.high", 'max');
    return 'probe-unknown' unless defined $high;
    push @limits, $high;
  }
  for my $cap (@limits) {
    next if $cap eq 'max';
    return 'memory' if _pp_mem_low($cap - $used, $cap < $ram ? $cap : $ram);
  }
  return undef unless $swap;
  if ($v2) {
    my $usage = _pp_knob("$d/memory.swap.current");
    my $cap = _pp_knob("$d/memory.swap.max", 'max');
    return 'probe-unknown' unless defined $usage && defined $cap;
    return 'swap' if $cap ne 'max' && _pp_swap_high($usage, $cap);
  } else {
    my $usage = _pp_knob("$d/memory.memsw.usage_in_bytes");
    my $cap = _pp_knob("$d/memory.memsw.limit_in_bytes");
    return 'probe-unknown' unless defined $usage && defined $cap;
    # v1 charges RAM and swap against a joint cap. The extra budget above
    # the RAM cap is all we can count on regardless of concurrent RAM usage.
    return 'swap' if _pp_swap_high($usage, $cap);
    if ($cap <= $ram + $swap) {
      my $stats = _pp_fields(_pp_file("$d/memory.stat", 32768), qr/\A(total_swap) ([0-9]+)\z/, 'total_swap');
      return 'probe-unknown' unless $stats;
      return 'swap' if _pp_swap_high($stats->{total_swap}, $cap > $limit ? $cap - $limit : 0);
    }
  }
  return undef;
}

sub _pp_linux_cgroups {
  my ($cpus, $ram, $swap) = @_;
  my $cg = _pp_file('/proc/self/cgroup', 65536);
  my $members = _pp_cgroup_members($cg);
  return (undef, 'probe-unknown') unless $members;
  return ($cpus, undef) unless keys %$members;
  my $mnt = _pp_cgroup_mounts(_pp_file('/proc/self/mountinfo', 1048576));
  return (undef, 'probe-unknown') unless $mnt;
  for my $c (qw(v2 cpu memory)) {
    next unless exists $members->{$c};
    return (undef, 'probe-unknown') unless exists $mnt->{$c};
    my $d = $mnt->{$c};
    my @levels = grep { length } split m{/}, $members->{$c};
    return (undef, 'probe-unknown') if @levels > 64;
    if ($c ne 'v2') {
      # Include v1 root, which exposes the control files as well.
      unshift @levels, '';
    }
    for my $level (@levels) {
      my ($cpu, $mem) = ($c eq 'cpu', $c eq 'memory');
      if ($c eq 'v2') {
        my $ctl = _pp_file("$d/cgroup.subtree_control", 4096);
        return (undef, 'probe-unknown') unless defined $ctl && $ctl =~ /\A(?:[a-z0-9_]+(?: [a-z0-9_]+)*)?\n?\z/;
        my %ctl = map { $_ => 1 } split /\s+/, $ctl;
        ($cpu, $mem) = @ctl{qw(cpu memory)};
      }
      $d .= "/$level" if length $level;
      return (undef, 'probe-unknown') unless -d ($d || '/');
      if ($cpu) {
        my $quota = _pp_cgroup_cpu($d, $c eq 'v2');
        return (undef, 'probe-unknown') unless defined $quota;
        $cpus = $quota if $quota ne 'max' && $quota < $cpus;
      }
      if ($mem) {
        my $why = _pp_cgroup_mem($d, $c eq 'v2', $ram, $swap);
        return (undef, $why) if defined $why;
      }
    }
  }
  my $after = _pp_file('/proc/self/cgroup', 65536);
  return (undef, 'probe-unknown') unless defined $after && $after eq $cg;
  return ($cpus, undef);
}

sub _pp_linux {
  my $cpus = _pp_linux_cpus();
  my $load = _pp_file('/proc/loadavg', 512);
  return 'probe-unknown' unless defined $cpus && defined $load
    && $load =~ /\A([0-9]{1,9}\.[0-9]{2}) [0-9]{1,9}\.[0-9]{2} [0-9]{1,9}\.[0-9]{2} [0-9]+\/[0-9]+ [0-9]+\n\z/;
  my $one = $1;
  my $mem = _pp_fields(_pp_file('/proc/meminfo', 32768), qr/\A(\w+):[ \t]+([0-9]+) kB\z/,
    qw(MemTotal MemAvailable SwapTotal SwapFree));
  return 'probe-unknown' unless $mem && $mem->{MemTotal} > 0 && $mem->{MemAvailable} <= $mem->{MemTotal}
    && $mem->{SwapFree} <= $mem->{SwapTotal};
  my ($ram, $avail, $swap, $free) = map { $mem->{$_} * 1024 } qw(MemTotal MemAvailable SwapTotal SwapFree);
  return 'load' if $one > 0.65 * $cpus;
  return 'memory' if _pp_mem_low($avail, $ram);
  return 'swap' if _pp_swap_high($swap - $free, $swap);
  my ($effective, $why) = _pp_linux_cgroups($cpus, $ram, $swap);
  return $why if defined $why;
  return 'load' if $one > 0.65 * $effective;
  my $vm = _pp_fields(_pp_file('/proc/vmstat', 65536), qr/\A(\w+) ([0-9]+)\z/, qw(pswpin pswpout));
  return 'probe-unknown' unless $vm;
  return join(':', 'linux', $swap ? 'on' : 'off', @{$vm}{qw(pswpin pswpout)});
}

sub _pp_darwin {
  my $sysctl = '/usr/sbin/sysctl';
  my $sys = _pp_exec(1024, $sysctl, '-n', qw(vm.loadavg hw.activecpu hw.memsize kern.memorystatus_vm_pressure_level));
  return 'probe-unknown' unless defined $sys
    && $sys =~ /\A\{ ([0-9]{1,9}\.[0-9]{2}) [0-9]{1,9}\.[0-9]{2} [0-9]{1,9}\.[0-9]{2} \}\n([1-9][0-9]{0,5})\n([1-9][0-9]{0,18})\n([124])\n\z/;
  my ($load, $cpus, $ram, $pressure) = ($1, $2, $3, $4);
  return 'load' if $load > 0.65 * $cpus;
  return 'memory' if $pressure != 1;
  my $mem = _pp_exec(1024, '/usr/bin/memory_pressure', '-Q');
  return 'probe-unknown' unless defined $mem
    && $mem =~ /\AThe system has ([1-9][0-9]{0,18}) \(([1-9][0-9]{0,18}) pages with a page size of ([1-9][0-9]{0,6})\)\.\nSystem-wide memory free percentage: (100|[1-9]?[0-9])%\n\z/
    && $1 == $ram && $2 * $3 == $ram;
  return 'memory' if _pp_mem_low($ram * $4 / 100, $ram);
  # struct xsw_usage: native-endian u64 total/avail/used and u32 page size and
  # encryption flag. Text sysctl rounds near the 80% trip point.
  my $raw = _pp_exec(128, $sysctl, '-b', 'vm.swapusage');
  return 'probe-unknown' unless defined $raw && length($raw) == 32;
  my ($total, $avail, $used, $page, $encrypted) = unpack('Q3L2', $raw);
  return 'probe-unknown' unless $used <= $total && $avail == $total - $used && $encrypted <= 1
    && ($page == 4096 || $page == 16384 || ($page == 0 && $total == 0));
  return 'swap' if _pp_swap_high($used, $total);
  my $vm = _pp_fields(_pp_exec(8192, '/usr/bin/vm_stat'), qr/\A(Swapins|Swapouts):[ \t]+([0-9]+)\.\z/,
    qw(Swapins Swapouts));
  return 'probe-unknown' unless $vm;
  return join(':', 'darwin', $total ? 'on' : 'off', @{$vm}{qw(Swapins Swapouts)});
}

sub _pp_disk {
  # Exact duplicate paths are removed by the caller. Probe every other path
  # even if it shares a device number: bind mounts or quotas can differ.
  for my $path (@_) {
    my ($total, $avail);
    if ($^O eq 'linux') {
      my $text = _pp_exec(4096, '/bin/df', '-k', '--output=size,avail', '--', $path);
      return 'probe-unknown' unless defined $text
        && $text =~ /\A[ \t]*1K-blocks[ \t]+Avail[ \t]*\n[ \t]*([0-9]+)[ \t]+(-?[0-9]+)[ \t]*\n\z/;
      ($total, $avail) = ($1, $2);
    } else {
      my $text = _pp_exec(8192, '/bin/df', '-Pk', $path);
      return 'probe-unknown' unless defined $text
        && $text =~ m{\AFilesystem[ \t]+1024-blocks[ \t]+Used[ \t]+Available[ \t]+Capacity[ \t]+Mounted on[ \t]*\n\S+[ \t]+([0-9]+)[ \t]+[0-9]+[ \t]+(-?[0-9]+)[ \t]+-?[0-9]+%[ \t]+/[^\x00-\x1f\x7f]*\n\z};
      ($total, $avail) = ($1, $2);
    }
    my $negative = $avail =~ s/\A-//;
    return 'probe-unknown' unless defined _pp_uint($total) && defined _pp_uint($avail) && $total > 0;
    return 'disk' if $negative;
    return 'probe-unknown' if $avail > $total;
    return 'disk' if $avail < 30 * 1024**2 || $avail < $total / 10;
  }
  return undef;
}

# List context: (opaque fingerprint, undef) or (undef, denial class).
# Compare complete fingerprints across samples; even a reset is not healthy.
sub pressure_probe {
  return (undef, 'probe-unknown') unless @_ && @_ <= 38 && ($^O eq 'linux' || $^O eq 'darwin');
  return (undef, 'probe-unknown') if grep { !_pp_abspath($_) } @_;
  my %seen;
  my @paths = grep { !$seen{$_}++ } @_;
  my $out = _pp_bounded(128, sub {
    my $sample = $^O eq 'linux' ? _pp_linux() : _pp_darwin();
    return $sample unless $sample =~ /:/;
    return _pp_disk(@paths) // $sample;
  });
  return ($out, undef) if defined $out && $out =~ /\A(?:linux|darwin):(?:on|off):[0-9]+:[0-9]+\z/;
  return (undef, $out) if defined $out && $out =~ /\A(?:load|memory|swap|disk)\z/;
  return (undef, 'probe-unknown');
}


# Discover from cwd, not a caller-supplied Git route (notably pre-push's
# GIT_DIR). Aliases and linked worktrees have the same common-dir inode.
sub gate_identity {
  my $identity = _pp_bounded(8192, sub {
    $ENV{GIT_CONFIG_NOSYSTEM} = 1;
    $ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
    my $git = -x '/usr/bin/git' ? '/usr/bin/git' : '/bin/git';
    my $out = _pp_exec(16384, $git, 'rev-parse', '--path-format=absolute',
      '--is-inside-work-tree', '--show-toplevel', '--git-common-dir');
    return undef unless defined $out && $out =~ m{\Atrue\n(/[\x20-\x7e]+)\n(/[\x20-\x7e]+)\n\z};
    my ($tree_path, $common_path) = ($1, $2);
    my ($worktree, $common) = (Cwd::abs_path($tree_path), Cwd::abs_path($common_path));
    return undef unless defined $worktree && defined $common && -d $worktree && -d $common;
    my @st = stat($common) or return undef;
    return "$st[0]:$st[1]\n$worktree";
  });
  return unless defined $identity && $identity =~ m{\A([0-9]+:[0-9]+)\n(/[\x20-\x7e]*)\z};
  return ($1, $2);
}

sub gate_disk_paths {
  my ($worktree) = @_;
  return undef unless defined $worktree;
  my $tmpdir = $caller{TMPDIR} // '/tmp';
  my $scratch = [];
  if (exists $caller{TRELLIS_HEAVY_GATE_SCRATCH_DIRS}) {
    $scratch = eval { JSON::PP->new->utf8->decode($caller{TRELLIS_HEAVY_GATE_SCRATCH_DIRS}) };
    return undef unless ref($scratch) eq 'ARRAY' && @$scratch <= 16;
  }
  my $docker_host = $caller{DOCKER_HOST} // '';
  my $local_sock;
  if (length($docker_host) && !@$scratch) {
    # An explicit container endpoint can store its data outside the checkout
    # and TMPDIR. Remote endpoints (tcp://, ssh://, etc.) fail closed unless
    # TRELLIS_HEAVY_GATE_SCRATCH_DIRS names their backing storage; local
    # unix:/// sockets (e.g. Colima/Docker Desktop injected by pre-push) resolve
    # to their local storage directory so pressure_probe checks its host volume.
    return undef unless $docker_host =~ m{\Aunix://(/[\x20-\x7e]+)\z};
    $local_sock = $1;
    return undef if $local_sock =~ m{/\z};
  }
  my $out = _pp_bounded(24000, sub {
    my @extra = @$scratch;
    if (defined $local_sock) {
      my $target = $local_sock;
      if (-e $local_sock || -l $local_sock) {
        return undef unless -S $local_sock;
        $target = Cwd::abs_path($local_sock);
        return undef unless defined $target && $target =~ m{\A/[\x20-\x7e]+\z};
      }
      my $sock_dir = $target;
      $sock_dir =~ s{/[^/]+\z}{};
      $sock_dir = '/' unless length($sock_dir);
      if ($^O eq 'linux' && $sock_dir =~ m{\A/run(?:/|\z)}) {
        return undef unless -d '/var/lib/docker';
        $sock_dir = '/var/lib/docker';
      }
      push @extra, $sock_dir;
    }
    my @paths;
    for my $path ($worktree, $dir, $tmpdir, @extra) {
      return undef unless defined $path && !ref($path) && $path =~ m{\A/[\x20-\x7e]*\z} && -d $path;
      my $real = Cwd::abs_path($path);
      return undef unless defined $real && $real =~ m{\A/[\x20-\x7e]*\z};
      push @paths, $real;
    }
    return join("\n", @paths);
  });
  return defined $out ? [split /\n/, $out] : undef;
}

sub observe_pressure {
  my ($holder, $repo, $paths, $last, $poll) = @_;
  return (undef, 'probe-unknown') unless $holder->{repo} && defined $repo;
  return (undef, 'same-repo') if $holder->{repo} eq $repo;
  return (undef, 'probe-unknown') unless $paths && ref($holder->{paths}) eq 'ARRAY' && @{$holder->{paths}} >= 3;
  my $started = monotime();
  my ($swap, $denial);
  my $fixture = test_knob('TRELLIS_HEAVY_TEST_PRESSURE');
  if (defined $fixture) {
    if (open(my $fh, '<', $fixture)) {
      my $line = <$fh> // '';
      chomp $line;
      if ($line =~ /\Ahealthy ([0-9]+)\z/) { $swap = $1; }
      elsif ($line =~ /\A(load|memory|swap|disk|probe-unknown)\z/) { $denial = $1; }
    }
  } else {
    ($swap, $denial) = pressure_probe(@$paths, @{$holder->{paths}});
  }
  return (undef, $denial // 'probe-unknown') unless defined $swap;
  my $sample = {token => $holder->{token}, swap => $swap, started => $started, at => monotime()};
  return ($sample, 'probe-unknown') unless $last && $last->{token} eq $holder->{token}
    && $started - $last->{started} >= $poll;
  return ($sample, 'swap') unless $swap eq $last->{swap};
  my $stagger = test_knob('TRELLIS_HEAVY_TEST_STAGGER') // 30;
  return ($sample, 'stagger') if $sample->{at} - $holder->{since} < $stagger;
  return ($sample, undef);
}

$mode eq 'run' or fail($EX_USAGE, "unknown supervisor mode: $mode");
my $pool = shift @ARGV // '';
$POOL{$pool} or fail($EX_USAGE, "unknown pool: $pool");
my $lane = shift @ARGV;
my $gate = $pool eq 'heavy' && $lane eq 'process-gate';
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

my $problem = prepare_dir();
fail($EX_CONFIG, $problem) if $problem;

my ($slot, $gate_position, $admission, @extra_locks);
my ($repo, $worktree) = $gate ? gate_identity() : ();
my $gate_paths = $gate ? gate_disk_paths($worktree) : undef;
sub exit_for_signal {
  unlink @published;
  POSIX::_exit(128 + $SIGNUM{$pending});
}

# Nested call: verified only when every check holds. A spoofed or stale marker
# fails, and the call then acquires a slot normally. The pool comes from the
# marker, never from this call's own --light: a holder of either pool counts.
sub verified_nested_fd {
  my ($fd, $slot, $id, $mpool) = @caller{qw(TRELLIS_HEAVY_FD TRELLIS_HEAVY_SLOT TRELLIS_HEAVY_DIR_ID TRELLIS_HEAVY_POOL)};
  return undef unless defined $mpool && ($mpool eq 'heavy' || $mpool eq 'light');
  return undef unless defined $fd && $fd =~ /^[0-9]+$/;
  return undef unless defined $slot && ($slot =~ /^[1-9][0-9]*$/ || ($mpool eq 'heavy' && $slot eq '0'));
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
  return 'lane' unless $mpool eq 'heavy';
  my $holder = gate_live($slot eq '0' ? 'primary' : 'overflow');
  if ($slot eq '0' || ($holder && ($holder->{slot} // '') eq $slot && ($holder->{token} // '') eq $token)) {
    fail($EX_USAGE, 'nested process-gate requires the enclosing physical Git repository')
      if $gate && !(defined $repo && $holder && ($holder->{repo} // '') eq $repo);
    return 'gate';
  }
  return 'lane';
}

my $nested = verified_nested_fd();
fail($EX_USAGE, 'run process-gate outside the enclosing ordinary heavy/light wrapper')
  if $gate && ($nested // '') eq 'lane';
my ($lock, %child_env);
%child_env = %caller;

# Transactions hold only the admission mutex and nonblocking slot attempts.
# No git, probe, wait, or workload is run under the mutex. A holder can exit
# concurrently; it cannot be replaced by a compatible entrant under us.
sub gate_acquire {
  my ($n, $sample, $denial) = @_;
  my ($primary, $overflow) = map { gate_live($_) } qw(primary overflow);
  my $holder = $primary // $overflow;
  my $reason;
  if ($primary && $overflow) {
    $reason = 'gate-full';
  } elsif ($holder) {
    if ($n->{gate} == 1 || ($overflow && ($overflow->{slot} // 0) > $n->{heavy})) {
      $reason = 'config';
    } elsif (!$holder->{repo} || !defined $repo) {
      $reason = 'probe-unknown';
    } elsif ($holder->{repo} eq $repo) {
      $reason = 'same-repo';
    } else {
      $reason = $denial;
      $reason //= 'probe-unknown' unless $sample && $sample->{token} eq $holder->{token}
        && monotime() - $sample->{started} <= 5;
    }
  }
  if (!$reason) {
    my ($repo_lock, $repo_state) = defined $repo ? try_slot('repo', $repo) : ();
    $reason = $repo_state eq 'held' ? 'same-repo' : 'probe-unknown' if $repo_state;
    fail($EX_CONFIG, 'cannot open repository permit') if ($repo_state // '') eq 'invalid';
    if (!$reason && !$primary) {
      my $state;
      ($lock, $state) = try_slot('heavy', 0);
      fail($EX_CONFIG, 'cannot open primary permit') if ($state // '') eq 'invalid';
      $reason = 'probe-unknown' unless $lock; # e.g. an old launcher raced
      ($slot, $gate_position) = (0, 'primary') if $lock;
    } elsif (!$reason) {
      my ($overflow_lock, $state) = try_slot('overflow', 1);
      fail($EX_CONFIG, 'cannot open overflow permit') if ($state // '') eq 'invalid';
      if ($overflow_lock) {
        for my $i (1 .. $n->{heavy}) {
          ($lock) = try_slot('heavy', $i);
          next unless $lock;
          ($slot, $gate_position) = ($i, 'overflow');
          push @extra_locks, $overflow_lock;
          last;
        }
        $reason = 'ordinary-full' unless $lock;
      } else {
        $reason = 'probe-unknown';
      }
    }
    push @extra_locks, $repo_lock if $lock && $repo_lock;
  }
  # Not evidence of ownership. Status uses this only as a short-lived
  # eligibility note tied to the actual holder (or as a historic denial).
  write_gate_record('last', {
    reason => $reason // 'none', at => monotime(), token => $holder ? $holder->{token} : undef,
  });
  return $reason;
}

sub handed_off {
  my $fh = shift;
  my $high = fcntl($fh, F_DUPFD, 64);
  defined $high or fail($EX_UNAVAILABLE, "could not duplicate the slot descriptor: $!");
  open(my $held, '+<&=', $high) or fail($EX_UNAVAILABLE, "could not adopt the slot descriptor: $!");
  fcntl($held, F_SETFD, 0) or fail($EX_UNAVAILABLE, "could not clear close-on-exec on the slot descriptor: $!");
  return ($held, $high);
}

my $block = POSIX::SigSet->new(SIGINT, SIGTERM, SIGHUP, SIGQUIT);
if (!$nested) {
  my $waited_since = monotime();
  my $last_heartbeat = $waited_since;
  my ($sample, $warning, $denial);
  while (1) {
    exit_for_signal() if $pending;
    my ($n, $why) = read_slots();
    fail($EX_CONFIG, $why) unless $n;
    my $probe_denial;
    if ($gate && $n->{gate} == 2) {
      my ($primary, $overflow) = map { gate_live($_) } qw(primary overflow);
      if (!!$primary != !!$overflow) {
        ($sample, $probe_denial) = observe_pressure($primary // $overflow, $repo, $gate_paths, $sample, $poll);
      } else {
        $sample = undef;
      }
    } else {
      $sample = undef;
    }
    exit_for_signal() if $pending;
    POSIX::sigprocmask(SIG_BLOCK, $block);
    if ($gate) {
      my $state;
      ($admission, $state) = try_slot('admission', 1);
      fail($EX_CONFIG, 'cannot open process-gate admission mutex') if ($state // '') eq 'invalid';
      if ($admission) {
        ($n, $why) = read_slots();
        fail($EX_CONFIG, $why) unless $n;
        $denial = gate_acquire($n, $sample, $probe_denial);
        undef $admission unless $lock;
      } else {
        $denial = 'admission-busy';
      }
    } else {
      for my $i (1 .. $n->{$pool}) {
        ($lock) = try_slot($pool, $i);
        if ($lock) { $slot = $i; last; }
      }
    }
    if ($n->{gate_warning} && !$warning++) {
      print STDERR "trellis heavy: $n->{gate_warning}\n";
    }
    if ($lock) {
      if (!$gate && (test_knob('TRELLIS_HEAVY_TEST_PAUSE') // '') eq 'after-acquire') {
        print STDERR "trellis heavy: test pause after-acquire slot=$slot\n";
        Time::HiRes::sleep(2);
      }
      # Cancellation check before unblocking: a signal that arrived during
      # acquisition is still pending here, so exit without forking. The
      # kernel drops the lock with the descriptor.
      my $set = POSIX::SigSet->new;
      POSIX::sigpending($set);
      for my $name (qw(INT TERM HUP QUIT)) {
        POSIX::_exit(128 + $SIGNUM{$name}) if $set->ismember($SIGNUM{$name});
      }
      last;    # still blocked: they stay blocked until the launch is armed
    }
    POSIX::sigprocmask(SIG_UNBLOCK, $block);
    exit_for_signal() if $pending;
    my $now = monotime();
    if ($now - $last_heartbeat >= $heartbeat) {
      $last_heartbeat = $now;
      printf STDERR "trellis heavy: waiting %ds for a %s slot (%s=%d); held: %s%s\n",
        $now - $waited_since, $gate ? 'process-gate' : $pool,
        $POOL{$pool}{key}, $n->{$pool}, held_summary($pool, $n->{$pool}),
        $gate ? "; process_gate_slots=$n->{gate} reason=$denial" : '';
    }
    Time::HiRes::sleep($poll);
  }

  # Hand the lock to the workload on a high descriptor with FD_CLOEXEC
  # cleared explicitly; perl's $^F is not relied on.
  my $high;
  ($lock, $high) = handed_off($lock);
  for my $extra (@extra_locks) { ($extra) = handed_off($extra); }
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
  if ($gate) {
    write_gate_record($gate_position, {
      token => $token, slot => $slot, repo => $repo, worktree => $worktree,
      paths => $gate_paths, since => monotime(),
    }) or fail($EX_UNAVAILABLE, 'could not publish process-gate ownership');
    push @published, gate_path($gate_position);
    undef $admission;
    if ((test_knob('TRELLIS_HEAVY_TEST_PAUSE') // '') eq 'after-acquire') {
      print STDERR "trellis heavy: test pause after-acquire slot=$slot\n";
      Time::HiRes::sleep(2);
    }
    printf STDERR "trellis heavy: admitted process-gate %s on slot-%d after %.1fs%s\n",
      $gate_position, $slot, monotime() - $waited_since,
      $gate_position eq 'overflow' ? ' (healthy; borrowed ordinary permit)' : '';
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
  for my $name (qw(INT TERM HUP QUIT)) {
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
      # Require a new scan started after observing the zombie: this scan's
      # initial PID enumeration may predate the leader's final forks.
      next;
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
unlink @published;
POSIX::_exit($EX_TIMEOUT) if ($teardown // '') eq 'timeout';
POSIX::_exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
