/**
 * trellis-bash-guard — bounds what one pi bash tool call can write and how
 * long it can run (spec 069 C1/C2). pi 1.1.0 spills any output past 50 KB to
 * a `pi-bash-*.log` with no size limit, and its bash tool has no default
 * timeout, so one runaway command can fill the disk unattended.
 *
 * The command is never re-quoted. It follows the wrapper verbatim, after a
 * separator line, and the wrapper reads it back from BASH_EXECUTION_STRING
 * (the `bash -c` argument pi passes), so it is parsed exactly as pi would
 * have parsed it. The outer shell stops at `exec` and never parses it.
 *
 * The wrapper execs perl, which keeps the PID pi waits on and runs the
 * command as its child, `bash -c` with stdout and stderr on one pipe. perl
 * passes at most the cap and then one marker line, and exits only after the
 * child has exited and the pipe has hit EOF or been idle for 100 ms (pi's own
 * grace for output after exit), so nothing the command wrote is left
 * unforwarded when pi stops reading, and a background job holding the pipe
 * does not hold the call. perl then exits with the child's status, or kills
 * itself with the child's signal. perl, not `head -c`: macOS head holds
 * output until 4 KiB or EOF and reads past the cap. A producer cut off by
 * the cap dies of SIGPIPE (exit 141); the marker says why. pi's timeout and
 * abort kill the whole process group, perl and the command alike.
 *
 * Effects outside this: the command runs in a child `bash -c`, so state a
 * shellCommandPrefix sets reaches it only when exported (Trellis's prefix
 * exports TMPDIR); its `$$` is that child, not the process pi spawned; and
 * `-c: line N` counts from the command's first line. Without perl on PATH
 * the command runs uncapped, with a notice on stderr.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const GUARD_MARKER = "# trellis-bash-guard v1";
const SEPARATOR = "# trellis-bash-guard: command follows";

// perl -e CAPPER <cap> <argv...>: run argv as a child, forward at most <cap>
// bytes of its output and the marker, then exit as the child did. The child's
// exit is polled, not caught: a SIGCHLD handler would interrupt a blocked
// syswrite and drop what it held. No single quotes: the wrapper
// single-quotes it.
const CAPPER = [
  "use POSIX (); use Config; my ($c, @cmd) = @ARGV;",
  'pipe(my $r, my $w) or die "trellis-bash-guard: pipe: $!\\n";',
  'my $pid = fork; die "trellis-bash-guard: fork: $!\\n" unless defined $pid;',
  'if (!$pid) { close $r; open(STDOUT, ">&", $w); open(STDERR, ">&", $w); close $w; exec { $cmd[0] } @cmd; exit 127 }',
  'close $w; my ($n, $st, $b) = (0); my $rin = ""; vec($rin, fileno($r), 1) = 1;',
  "while (1) {",
  "  $st = $? if !defined $st && waitpid($pid, POSIX::WNOHANG()) == $pid;",
  "  my $ready = select(my $rout = $rin, undef, undef, defined $st ? 0.1 : 0.05);",
  "  if ($ready > 0) {",
  "    my $k = sysread($r, $b, 65536); last unless $k;",
  '    if ($n + $k > $c) { syswrite(STDOUT, $b, $c - $n); syswrite(STDOUT, "\\n[trellis-bash-guard: output truncated at $c bytes]\\n"); last }',
  "    $n += $k; syswrite(STDOUT, $b);",
  "  } elsif ($ready == 0 && defined $st) { last }",
  "}",
  "close $r; if (!defined $st) { waitpid($pid, 0); $st = $? }",
  'if (my $sig = $st & 127) { $SIG{(split " ", $Config{sig_name})[$sig]} = "DEFAULT"; kill $sig, $$; exit 128 + $sig }',
  "exit($st >> 8);",
].join("\n");

/** The wrapped command, or `command` itself when the cap is 0 or it is already wrapped. */
export function guardCommand(command: string, capBytes: number): string {
  if (capBytes === 0 || command.startsWith(GUARD_MARKER + "\n")) return command;
  return [
    GUARD_MARKER,
    `__trellis_guard_cmd=\${BASH_EXECUTION_STRING#*$'\\n${SEPARATOR}\\n'}`,
    `[ "$__trellis_guard_cmd" != "\${BASH_EXECUTION_STRING-}" ] || { echo 'trellis-bash-guard: the command was not found in BASH_EXECUTION_STRING; not run' >&2; exit 125; }`,
    `command -v perl >/dev/null 2>&1 || { echo 'trellis-bash-guard: perl not found; output is not capped' >&2; exec "$BASH" -c "$__trellis_guard_cmd"; }`,
    `exec perl -e '${CAPPER}' ${capBytes} "$BASH" -c "$__trellis_guard_cmd"`,
    "exit 126",
    SEPARATOR,
    command,
  ].join("\n");
}

export const DEFAULT_TIMEOUT_S = 1800;
export const DEFAULT_CAP_BYTES = 536870912;
// pi rejects a timeout whose milliseconds exceed 2^31 - 1.
const MAX_TIMEOUT_S = 2147483;

/**
 * The timeout and cap from TRELLIS_PI_BASH_TIMEOUT_S and
 * TRELLIS_PI_BASH_CAP_BYTES; 0 turns either off. A value that is not a whole
 * number in range is replaced by the default and named in `invalid`, which
 * the doctor row reports.
 */
export function guardSettings(env: Record<string, string | undefined>) {
  const invalid: string[] = [];
  const read = (name: string, fallback: number, max: number) => {
    const raw = env[name];
    if (raw === undefined || raw === "") return fallback;
    const value = Number(raw);
    if (/^\d+$/.test(raw) && value <= max) return value;
    invalid.push(name);
    return fallback;
  };
  const timeoutS = read("TRELLIS_PI_BASH_TIMEOUT_S", DEFAULT_TIMEOUT_S, MAX_TIMEOUT_S);
  const capBytes = read("TRELLIS_PI_BASH_CAP_BYTES", DEFAULT_CAP_BYTES, Number.MAX_SAFE_INTEGER);
  return { timeoutS, capBytes, invalid };
}

export default function (pi: ExtensionAPI) {
  // Mutating event.input is how a tool_call handler changes a call (pi
  // docs/extensions.md); returning nothing lets it run.
  pi.on("tool_call", (event) => {
    if (event.toolName !== "bash") return;
    const input = event.input as { command: unknown; timeout?: number };
    // Model-written input: a call pi will reject anyway is left untouched.
    if (typeof input.command !== "string") return;
    const { timeoutS, capBytes } = guardSettings(process.env);
    if (input.timeout === undefined && timeoutS > 0) input.timeout = timeoutS;
    input.command = guardCommand(input.command, capBytes);
  });
}
