#!/usr/bin/perl
# guard-supervise.pl <claude|codex|pi> <hook-name> <command> [args...]
#
# Supervisor for the bright-line PreToolUse guards. Claude Code cancels a
# PreToolUse command hook at its registered `timeout` and lets the tool call
# run, so a guard that stalls, crashes or prints garbage must never be what the
# client sees. Registrations start this file through a POSIX sh entry (see the
# templates) that clears PERL5OPT, PERL5LIB, PERLLIB, PERL5DB, ENV and
# BASH_ENV, denies when perl or this file is missing, and denies on any exit
# other than the codes below. The pi dispatcher calls it directly in pi mode.
#
#   - Budget: DEADLINE_SECS from this process's start ($^T, whole seconds,
#     rounded down, so the budget never exceeds it). It covers reading the
#     event, the guard's interpreter start-up and every library it sources.
#     The sh entry and the client's own spawn come before it. Registered client
#     timeout is 30 s.
#   - stdin: read here, under the deadline, and given to the guard from a spool
#     file; the guard and its descendants never hold the client's stdin.
#   - stdout/stderr: the guard writes to pipes owned here. If the guard exits
#     with its stdout still open after a short drain, that is a refusal.
#   - Deadline: kill the guard's process group, then refuse.
#   - claude: no-op = exit 0 + empty stdout; decision = exactly one
#     {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":
#     "allow|deny|ask",...}}. Anything else, including the guard's own exit 2,
#     becomes a deny document.
#   - codex: no-op = exit 0 + empty stdout; block = exactly one
#     {"decision":"block","reason":"..."} (client exit 2). Anything else blocks.
#   - pi: as codex, and an advisory {"hookSpecificOutput":{"additionalContext":
#     "..."}} also passes; a nonzero worker exit passes through unchanged for
#     the dispatcher, which denies it.
#
# Exit codes to the sh entry: 10 no-op, 11 document on stdout (client exit 0),
# 12 block on stdout (client exit 2). pi mode exits 0 or 2 (or the worker's).
# This file reads no environment variable and takes no option that changes the
# deadline or skips supervision.
use strict;
use warnings;

my $DEADLINE_SECS = 20;
my $CAPTURE_MAX = 1 << 20;
my $INPUT_MAX = 64 << 20;
my $deadline = $^T + $DEADLINE_SECS;

my ($harness, $hook, @cmd) = @ARGV;
$harness = '' unless defined $harness;
$hook = 'guard' unless defined $hook && $hook =~ /\A[a-z0-9-]{1,64}\z/;
my ($pid, $child_err) = (undef, '');

sub finish {
  my ($text, $code) = @_;
  print STDOUT $text if length $text;
  exit $code;
}

sub refuse {
  my ($why) = @_;
  if ($pid) {
    # -$pid is the group the guard made with setsid(); before that call no
    # group has that id and the group kill fails harmlessly. TERM is ignored
    # here so a signal that reaches our own group cannot cut the refusal.
    local $SIG{TERM} = 'IGNORE';
    kill('TERM', -$pid, $pid);
    select(undef, undef, undef, 0.2);
    kill('KILL', -$pid, $pid);
    $pid = undef;
  }
  my $reason = "$hook: $why; refusing";
  $reason =~ s/[^\x20-\x7e]//g;
  (my $json = $reason) =~ s/(["\\])/\\$1/g;
  if ($harness eq 'claude') {
    print STDERR $child_err if length $child_err;
    finish(qq({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$json"}}\n), 11);
  }
  print STDERR "$reason\n";
  finish(qq({"decision":"block","reason":"$json"}\n), $harness eq 'pi' ? 2 : 12);
}

$SIG{PIPE} = 'IGNORE';
$SIG{$_} = sub { refuse("supervisor received SIG$_[0]") } for qw(TERM INT HUP QUIT USR1 USR2 ALRM);
eval { require POSIX; require Time::HiRes; require JSON::PP; 1 }
  or refuse('supervisor could not load its modules');
eval { main(); 1 } or refuse('supervisor failed');

sub now { Time::HiRes::time() }

# Read the whole event under the deadline. Nothing descends from here yet.
sub read_input {
  my $in = '';
  binmode STDIN;
  while (1) {
    my $wait = $deadline - now();
    refuse("guard timed out after ${DEADLINE_SECS}s reading its input") if $wait <= 0;
    my $rin = '';
    vec($rin, fileno(STDIN), 1) = 1;
    my $ready = select(my $rout = $rin, undef, undef, $wait);
    next if $ready <= 0;
    my $n = sysread(STDIN, my $chunk, 65536);
    refuse('supervisor could not read its input') unless defined $n;
    last if $n == 0;
    $in .= $chunk;
    refuse('guard input exceeded the capture limit') if length $in > $INPUT_MAX;
  }
  close STDIN;
  return $in;
}

sub valid_doc {
  my ($doc) = @_;
  return 0 unless ref $doc eq 'HASH';
  my $h = $doc->{hookSpecificOutput};
  my $decision = ref $h eq 'HASH' && ($h->{hookEventName} // '') eq 'PreToolUse'
    && ($h->{permissionDecision} // '') =~ /\A(?:allow|deny|ask)\z/;
  my $block = ($doc->{decision} // '') eq 'block' && defined $doc->{reason} && !ref $doc->{reason};
  return $decision ? 'decision' : 0 if $harness eq 'claude';
  return $block ? 'block' : 0 if $harness eq 'codex';
  my $advice = ref $h eq 'HASH' && defined $h->{additionalContext} && !ref $h->{additionalContext};
  return $block ? 'block' : ($decision || $advice) ? 'decision' : 0;
}

sub main {
  refuse('supervisor called with an unknown harness') unless $harness =~ /\A(?:claude|codex|pi)\z/;
  refuse('supervisor called without a guard command') unless @cmd;
  my $input = read_input();
  open(my $spool, '+>', undef) or refuse('supervisor could not spool the input');
  binmode $spool;
  print {$spool} $input or refuse('supervisor could not spool the input');
  $spool->flush;
  seek($spool, 0, 0) or refuse('supervisor could not spool the input');

  pipe(my $out_r, my $out_w) or refuse('supervisor could not create its pipes');
  pipe(my $err_r, my $err_w) or refuse('supervisor could not create its pipes');
  my $child = fork();
  defined $child or refuse('supervisor could not start the guard');
  if ($child == 0) {
    $SIG{PIPE} = 'DEFAULT';
    close $out_r;
    close $err_r;
    POSIX::setsid() or POSIX::_exit(125);
    open(STDIN, '<&', $spool) or POSIX::_exit(125);
    open(STDOUT, '>&', $out_w) or POSIX::_exit(125);
    open(STDERR, '>&', $err_w) or POSIX::_exit(125);
    exec { $cmd[0] } @cmd or POSIX::_exit(127);
  }
  $pid = $child;
  close $out_w;
  close $err_w;
  close $spool;

  my %fh = (out => $out_r, err => $err_r);
  my %buf = (out => '', err => '');
  my ($status, $grace_until);
  while (1) {
    my $now = now();
    refuse("guard timed out after ${DEADLINE_SECS}s") if $now >= $deadline;
    if (!defined $status && waitpid($pid, POSIX::WNOHANG()) == $pid) {
      $status = $?;
      # What the guard wrote is already in the pipes; a descendant that keeps
      # them open gets a short drain, never the budget.
      $grace_until = $now + 0.2;
    }
    if (defined $status && (!%fh || $now >= $grace_until)) {
      refuse('guard exited with its output still open') if $fh{out};
      last;
    }
    my $wait = $deadline - $now;
    $wait = 0.05 if $wait > 0.05;
    if (!%fh) { select(undef, undef, undef, $wait); next; }
    my $rin = '';
    vec($rin, fileno($fh{$_}), 1) = 1 for keys %fh;
    next unless select(my $rout = $rin, undef, undef, $wait) > 0;
    for my $k (keys %fh) {
      next unless vec($rout, fileno($fh{$k}), 1);
      my $n = sysread($fh{$k}, my $chunk, 65536);
      if (!$n) { close $fh{$k}; delete $fh{$k}; next; }
      $buf{$k} .= $chunk;
      refuse('guard output exceeded the capture limit') if length $buf{$k} > $CAPTURE_MAX;
    }
  }
  close $_ for values %fh;
  my $guard = $pid;
  $pid = undef;

  my $signal = $status & 127;
  my $code = $status >> 8;
  my $text = $buf{out};
  $text =~ s/\A\s+|\s+\z//g;
  my $kind = '';
  if ($text ne '') {
    my $doc = eval { JSON::PP->new->decode($text) };
    $kind = valid_doc($doc);
  }

  if ($harness eq 'pi') {
    if ($signal || $code != 0) {
      print STDERR $buf{err};
      finish($buf{out}, $signal ? 128 + $signal : $code);
    }
    refuse('guard output is not exactly one decision document') if $text ne '' && !$kind;
    print STDERR $buf{err};
    finish($buf{out}, 0);
  }

  $child_err = $buf{err};
  refuse("guard was killed by signal $signal") if $signal;
  refuse('guard could not be started') if $code == 125 || $code == 127;
  if ($harness eq 'claude' && $code == 2) {
    (my $first = (split /\n/, $buf{err})[0] // '') =~ s/[^\x20-\x7e]//g;
    refuse('guard refused' . (length $first ? " ($first)" : '') . ' with exit 2');
  }
  refuse("guard exited $code without a decision") unless $code == 0 || $code == 2;
  refuse('guard output is not exactly one decision document') if $text ne '' && !$kind;
  refuse('guard blocked without a decision document') if $code == 2 && $kind ne 'block';
  print STDERR $buf{err};
  finish('', 10) if $text eq '';
  finish($buf{out}, $kind eq 'block' ? 12 : 11);
}
