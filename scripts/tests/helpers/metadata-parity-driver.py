"""T59 four-route differential; safety rulings override legacy jq acceptance."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

launcher, jq_script, supervisor, cases_dir, config_path, output = sys.argv[1:]
config = Path(config_path)
routes = {"version": ["--version"], "help": ["help"], "check": ["heavy", "--check"], "status": ["heavy", "--status"]}
env = dict(os.environ)

def run(argv, case, route):
    started = time.monotonic()
    child = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = child.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        elapsed = time.monotonic() - started
        raise AssertionError(f"bounded parity command timed out: case={case} route={route} elapsed={elapsed:.3f}s limit=5s argv={argv}")
    return child.returncode, out, err

def strict_difference(case, raw):
    if len(raw) > 32768:
        return "metadata-only 32768-byte ceiling"
    if b"\0" in raw:
        return "NUL forbidden"
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return "invalid UTF8 forbidden"
    # Perl's strict UTF-8 also refuses noncharacters: accepted fail-closed.
    if any(0xFDD0 <= ord(char) <= 0xFDEF or ord(char) & 0xFFFF in (0xFFFE, 0xFFFF) for char in text):
        return "Perl strict UTF8 noncharacter refusal"
    if case.startswith(("two-valid", "inv-then-valid", "one-then-valid", "arr-then-valid")):
        return "single object required"
    if case.startswith(tuple(f"proj-{n:02d}-" for n in (4, 5, 6, 7, 8))):
        return "unsupported decNumber token"
    # Host-independent conservative bound; jq1.8 accepts more than jq1.7.
    depth = 0
    quoted = escaped = False
    for byte in raw:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (123, 91):
            depth += 2 if byte == 123 else 1
            if depth > 256:
                return "conservative parser-stack bound"
        elif byte in (125, 93):
            depth -= 2 if byte == 125 else 1
    if re.search(rb"[eE][+-]?[0-9]{7,}", raw):
        return "bounded exponent literal"
    return None

rows = []
for case in sorted(Path(cases_dir).glob("*.json")):
    raw = case.read_bytes()
    config.write_bytes(raw)
    config.chmod(0o600)
    oracle, _, _ = run(["/bin/bash", jq_script, str(config)], case.name, "jq")
    strict = strict_difference(case.name, raw)
    admitted = oracle == 0 and strict is None
    row = {"case": case.name, "jq": oracle, "strict": strict, "routes": {}}
    for name, args in routes.items():
        expected = 0 if admitted else 4
        gate_case = case.name.startswith(("val-process_gate_slots-", "gate-escaped-key"))
        direct = None
        if admitted and name in ("check", "status"):
            expected, direct_out, direct_err = run(["/usr/bin/perl", supervisor, name], case.name, "supervisor-" + name)
            if gate_case:
                direct = (direct_out, direct_err)
        actual, out, err = run([launcher, *args], case.name, name)
        row["routes"][name] = {"expected": expected, "actual": actual}
        if actual != expected or (direct is not None and (out, err) != direct):
            row["failure"] = {"route": name, "stdout": out[-1000:].decode("utf-8", "replace"), "stderr": err[-1000:].decode("utf-8", "replace")}
            rows.append(row)
            Path(output).write_text(json.dumps(rows, indent=2)+"\n")
            raise AssertionError(f"{case.name}/{name}: jq={oracle} strict={strict} expected={expected} actual={actual}: {out[-200:]!r} {err[-200:]!r}; supervisor={direct!r}")
        if gate_case and admitted and name in ("check", "status"):
            requested = json.loads(raw)["process_gate_slots"]
            valid = type(requested) is int and requested in (1, 2)
            cap = requested if valid else 1
            assert actual == 0 and re.search(rb"\bprocess_gate_slots=" + str(cap).encode() + rb"\b", out), (case.name, name, out, err)
            assert (b"process_gate_slots must be" in err) == (not valid), (case.name, name, out, err)
            if name == "status" and not valid:
                assert b"effective_process_gate_slots=1" in out, (case.name, name, out, err)
    rows.append(row)
Path(output).write_text(json.dumps(rows, indent=2)+"\n")
print(f"{len(rows)} configs x {len(routes)} metadata routes agree with canonical or named stricter safety ruling")
