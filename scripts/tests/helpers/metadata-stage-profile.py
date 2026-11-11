#!/usr/bin/env python3
"""Test-only T59 stage profile of the exact production Perl prefix.

python3 -I scripts/tests/helpers/metadata-stage-profile.py --out /tmp/new-private-dir

No normal-run timeout. Default one run of review big-projects-1mb.json. Retains
original/instrumented Perl, hashes, stdout/stderr, stage wall/user/sys and load.
This is functional CPU diagnosis, not SC9 qualification. Production is not edited.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import runpy
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--runs", type=int, choices=range(1, 6), default=1)
    parser.add_argument("--config-bytes", type=int, default=1000195)
    parser.add_argument("--shape", choices=("string", "array"), default="string")
    parser.add_argument("--expected-exit", type=int, choices=(0, 4), default=0)
    args = parser.parse_args()
    out = args.out.absolute()
    out.mkdir(mode=0o700)  # exclusive: never overwrite or clean operator state
    out = out.resolve(strict=True)
    home, trellis, tmp = (out / name for name in ("home", "trellis-home", "tmp"))
    for directory in (home, trellis, tmp):
        directory.mkdir(mode=0o700)
    env = {"HOME": str(home), "TRELLIS_HOME": str(trellis), "TMPDIR": str(tmp),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_CONFIG_GLOBAL": str(out / "gitconfig")}
    (out / "gitconfig").write_text("")
    make = runpy.run_path(str(args.repo / 'scripts/tests/helpers/metadata-large-config-probe.py'))['fixture_bytes']
    raw, case = make(args.config_bytes, args.shape)
    digest = hashlib.sha256(raw).hexdigest()
    if args.config_bytes == 1000195 and args.shape == 'string':
        assert digest == "9add765c0a308d51ce10a38f243ec56ddf17657e517eaa4028a547b481699b2a"
    (trellis / "config.json").write_bytes(raw)
    (trellis / "config.json").chmod(0o600)
    template = (args.repo / "scripts/trellis-launcher.sh").read_text()
    start = "  cat <<'TRELLIS_METADATA_PL'\n"
    end = "\nTRELLIS_METADATA_PL\n"
    assert template.count(start) == 1
    original = template.split(start, 1)[1].split(end, 1)[0] + "\n"
    (out / "original-metadata.pl").write_text(original)
    program = original

    def replace(old, new):
        nonlocal program
        assert program.count(old) == 1, (old, program.count(old))
        program = program.replace(old, new, 1)

    replace("open(my $metadata_fh, '<', $metadata_path)", "stage_begin('read');\nopen(my $metadata_fh, '<', $metadata_path)")
    close_lines = [line for line in program.splitlines() if 'close $metadata_fh;' in line]
    assert len(close_lines) == 1
    replace(close_lines[0], close_lines[0]+"\nstage_end('read');")
    replace('  my $nul = index($raw, "\\0");', '  stage_begin("nul_scan");\n  my $nul = index($raw, "\\0");\n  stage_end("nul_scan");')
    utf8_lines = [line for line in program.splitlines() if "Encode::decode('UTF-8', $raw" in line]
    assert len(utf8_lines) == 1
    utf8 = utf8_lines[0]
    indent = utf8[:len(utf8)-len(utf8.lstrip())]
    replace(utf8, indent+'stage_begin("utf8_including_encode_noncharacters");\n' + utf8 + '\n'+indent+'stage_end("utf8_including_encode_noncharacters");')
    # Encode FB_CROAK combines structural UTF8 and noncharacter refusal. The
    # additional scan is diagnostic-only, labelled separately, not misattributed
    # to a second production check. No per-character timing calls are injected.
    noncharacters = "".join("\\x{" + format(cp, "x") + "}" for plane in range(17) for cp in (plane * 65536 + 65534, plane * 65536 + 65535))
    checked = indent+'return undef unless defined $text;'
    replace(checked, checked+"\n"+indent+"stage_begin('noncharacter_scan_diagnostic_only');\n"+indent+"my $noncharacter = $text =~ /[\\x{fdd0}-\\x{fdef}" + noncharacters + "]/;\n"+indent+"stage_end('noncharacter_scan_diagnostic_only');")
    encoded = indent+'utf8::encode($text);'
    if encoded in program:
        replace(encoded, indent+"stage_begin('byte_reencode');\n"+encoded+"\n"+indent+"stage_end('byte_reencode');")
    replace("  my ($out, $i, $depth, $top_key) = ('', 0, 0, '');", "  stage_begin('lexical_scan_and_schema_literal_extraction');\n  my ($out, $i, $depth, $top_key) = ('', 0, 0, '');")
    replace("  return $out;", "  stage_end('lexical_scan_and_schema_literal_extraction');\n  return $out;")
    replace("  return 0 unless metadata_one($metadata_schema_literal);", "  stage_begin('schema_literal_comparison');\n  my $literal_one = metadata_one($metadata_schema_literal);\n  stage_end('schema_literal_comparison');\n  return 0 unless $literal_one;")
    decode_lines = [line for line in program.splitlines() if line.startswith("my $metadata_data = eval {")]
    assert len(decode_lines) == 1
    decode = decode_lines[0]
    replace(decode, "stage_begin('jsonpp_decode');\n" + decode + "\nstage_end('jsonpp_decode');")
    fields = 'metadata_error("machine config failed validation: $metadata_path") unless metadata_valid($metadata_data);'
    replace(fields, "stage_begin('field_checks_including_literal_comparison');\nmy $valid = metadata_valid($metadata_data);\nstage_end('field_checks_including_literal_comparison');\nmetadata_error(\"machine config failed validation: $metadata_path\") unless $valid;")
    preamble = r'''use Time::HiRes ();
my (%stage_active, %stage_profile);
sub stage_begin {
  my ($name) = @_; my ($user,$sys) = times();
  $stage_active{$name} = [Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()),$user,$sys];
}
sub stage_end {
  my ($name) = @_; my ($user,$sys) = times(); my $start = delete $stage_active{$name};
  $stage_profile{$name}{wall_seconds} += Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())-$start->[0];
  $stage_profile{$name}{user_cpu_seconds} += $user-$start->[1];
  $stage_profile{$name}{sys_cpu_seconds} += $sys-$start->[2];
}
END { print STDERR "METADATA_STAGE_PROFILE ",JSON::PP->new->canonical->encode(\%stage_profile),"\n"; }
'''
    instrumented = out / "instrumented-metadata.pl"
    instrumented.write_text(preamble + program)
    result = {"kind": "T59-stage-profile-not-SC9", "case": case, "expected_exit": args.expected_exit,
              "config_bytes": len(raw), "config_sha256": digest,
              "normal_run_timeout": None, "load_start": list(os.getloadavg()),
              "logical_cpus": os.cpu_count(),
              "original_perl_sha256": hashlib.sha256(original.encode()).hexdigest(),
              "instrumented_sha256": hashlib.sha256(instrumented.read_bytes()).hexdigest(),
              "notes": ["UTF8 and noncharacter refusal are combined by production Encode FB_CROAK.",
                        "The extra noncharacter scan is diagnostic only.",
                        "Lexical scan includes production top-level key decoding and schema literal extraction.",
                        "Field checks include the separately reported literal comparison; do not sum overlapping stages.",
                        "Perl times() CPU resolution is host-dependent; outer rusage records total CPU."],
              "observations": []}
    receipt = out / "results.json"
    receipt.write_text(json.dumps(result, indent=2) + "\n")
    for number in range(1, args.runs + 1):
        print(f"START stage-profile run={number} load={os.getloadavg()}", flush=True)
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        started = time.monotonic()
        child = subprocess.Popen(["/usr/bin/perl", str(instrumented), "version", "1"], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = child.communicate()  # intentionally unbounded
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            raise
        wall = time.monotonic() - started
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        (out / f"run-{number}.stdout").write_bytes(stdout)
        (out / f"run-{number}.stderr").write_bytes(stderr)
        marker = b"METADATA_STAGE_PROFILE "
        stage_lines = [line[len(marker):] for line in stderr.splitlines() if line.startswith(marker)]
        assert len(stage_lines) == 1, stderr
        row = {"run": number, "exit": child.returncode, "wall_seconds": wall,
               "user_cpu_seconds": after.ru_utime-before.ru_utime,
               "sys_cpu_seconds": after.ru_stime-before.ru_stime,
               "load_end": list(os.getloadavg()), "stages": json.loads(stage_lines[0])}
        result["observations"].append(row)
        receipt.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(row, sort_keys=True), flush=True)
        expected_stdout = b"" if args.expected_exit == 4 else b"trellis 1.2.3 (configured; not verified)\n"
        assert child.returncode == args.expected_exit and stdout == expected_stdout, (child.returncode, stdout, stderr)
    print(f"Retained {receipt}; no production change or SC9 claim", flush=True)


if __name__ == "__main__":
    main()
