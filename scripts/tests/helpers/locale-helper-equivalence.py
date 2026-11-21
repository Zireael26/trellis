#!/usr/bin/env python3
"""Compare migrated helpers to their original C-locale bytes, without shell locale changes."""
import errno
import os
from pathlib import Path
import re
import subprocess
import sys

bash, root, scratch = sys.argv[1:]
root, scratch = Path(root), Path(scratch)
oracle = (root / "scripts/tests/fixtures/locale-c-oracle.txt").read_text(encoding="utf-8")
environment = {k: v for k, v in os.environ.items()
               if k not in ("LANG", "LANGUAGE") and not k.startswith("LC_")}
environment["TRELLIS_HOME"] = str(scratch / "state-home")
locales = [{}, {"LANG": "C"}, {"LANG": "en_US.UTF-8"},
           {"LC_ALL": ""}, {"LC_ALL": "C"}, {"LC_ALL": "en_US.UTF-8"}]
available = subprocess.check_output(["locale", "-a"], env=dict(environment, LC_ALL="C")).decode("ascii", "replace")
c_utf8 = next((name for name in available.splitlines() if name.lower().replace("-", "") == "c.utf8"), None)
if c_utf8:
    locales.append({"LC_ALL": c_utf8})
else:
    print("C.UTF-8 locale unavailable on this host; en_US.UTF-8 cases remain in the matrix")


def function(text, name):
    header = re.search(r"(?m)^" + re.escape(name) + r"[ \t]*\([ \t]*\)[ \t]*([({])[ \t]*(?:#[^\n]*)?\n", text)
    assert header, name
    closing = "}" if header[1] == "{" else ")"
    end = re.search(r"(?m)^" + re.escape(closing) + r"(?=[ \t]*(?:$|#))", text[header.end():])
    assert end, name
    return text[header.start():header.end() + end.end()] + "\n"


def production(path, *names):
    text = (root / path).read_text(encoding="utf-8")
    return "\n".join(function(text, name) for name in names)


def compare(label, current, names, values, call, prelude=""):
    probe = prelude + "\nwhile IFS= read -r -d '' value; do\n" + call + "\ndone\n"
    payload = b"\0".join(values) + b"\0"
    old = "\n".join(function(oracle, name) for name in names)

    def run(source, locale):
        result = subprocess.run([bash, "-c", source + probe], input=payload,
                                env=dict(environment, **locale), capture_output=True)
        assert result.returncode == 0, (label, locale, result.returncode, result.stderr)
        return result.stdout

    expected = run(old, {"LC_ALL": "C"})
    for locale in locales:
        actual = run(current, locale)
        if actual != expected:
            offset = next((i for i, (a, e) in enumerate(zip(actual, expected)) if a != e),
                          min(len(actual), len(expected)))
            raise AssertionError((label, locale, f"first differing byte {offset}",
                                  actual[max(0, offset - 20):offset + 60],
                                  expected[max(0, offset - 20):offset + 60]))
    print(f"{label}: {len(values)} inputs x {len(locales)} locales match original C")


values = [b"", b"ordinary ASCII", "café 日本 K".encode(), b"\xc0\x80", b"\xe2\x82", b"\xf5\xff"]
values += [b"x" + bytes([n]) + b"z" for n in range(1, 256)]
values += [b"x\xc2" + bytes([n]) + b"z" for n in range(1, 256)]
values += ["é".encode() + b"\x01" + bytes([n]) for n in range(1, 256)]
for path, name, call in (
    ("scripts/lib/attachment.sh", "_attachment_visible", '_attachment_visible "$value"; printf "\\0%s\\0" "$?"'),
    ("scripts/doctor.sh", "shared_infra_safe_line", 'shared_infra_safe_line "$value"; printf "\\0%s\\0" "$?"'),
    ("scripts/lib/guard-rules-runtime.bash", "_gr_json_str", '_gr_json_str "$value"; rc=$?; printf "%s\\0%s\\0" "$GR_JSON" "$rc"'),
):
    compare(name, production(path, name), [name], values, call)

config_dir = scratch / "configs"
config_dir.mkdir()
configs = [b"", b"# comment\n", b"SECURITY_GATE_AUDIT_DIR=audits\n",
           b'SECURITY_GATE_AUDIT_DIR="${SECURITY_GATE_AUDIT_DIR:-audits}"\n',
           b'SECURITY_GATE_AUDIT_DIR="one"\nSECURITY_GATE_AUDIT_DIR=two\n',
           b"SECURITY_GATE_AUDIT_DIR='a b' # comment\r\n", b"LLM_MODEL=model\n",
           b"UNKNOWN=value\n", b"SECURITY_GATE_AUDIT_DIR=$(evil)\n",
           b'SECURITY_GATE_AUDIT_DIR=first\nSECURITY_GATE_AUDIT_DIR="${SECURITY_GATE_AUDIT_DIR:-second}"\n']
for literal in [b'"unterminated', b"'unterminated", b'"ok"junk', b"'ok'junk", b'"ok" # comment',
                b'"ok"#not-comment', b'"${OTHER:-bad}"', b'"${SECURITY_GATE_AUDIT_DIR:-}"',
                b'"${SECURITY_GATE_AUDIT_DIR:-{nested}"', b'"${SECURITY_GATE_AUDIT_DIR:-bad}extra}"',
                b'"${SECURITY_GATE_AUDIT_DIR:-$bad}"', b'"${SECURITY_GATE_AUDIT_DIR:-x:-y}"',
                b"'literal $ ` \\ text'", b"bare # comment", b"bare#not-comment", b" # comment"]:
    configs.append(b"SECURITY_GATE_AUDIT_DIR=" + literal + b"\n")
for data in [bytes([n]) for n in range(1, 256)] + ["é".encode(), "\u2003".encode(), "K".encode()]:
    configs += [b'SECURITY_GATE_AUDIT_DIR="x' + data + b'y"\n',
                data + b"SECURITY_GATE_AUDIT_DIR=audits\n",
                b"SECURITY_GATE_AUDIT_DIR=audits" + data + b"\n",
                b"SECURITY_GATE_" + data + b"=audits\n",
                b"SECURITY_GATE_AUDIT_DIR='x" + data + b"y'\n",
                b'SECURITY_GATE_AUDIT_DIR="${SECURITY_GATE_AUDIT_DIR:-x' + data + b'y}"\n']
paths = []
for n, content in enumerate(configs):
    path = config_dir / str(n)
    path.write_bytes(content)
    paths.append(os.fsencode(path))
for path, name in (
    ("core-rules/skills/process-gate/scripts/run-all.sh", "pg_audit_dir_values"),
    ("core-rules/skills/security-gate/scripts/lib/engine.sh", "sg_parse_local_config"),
    ("core-rules/skills/security-gate/scripts/run-diff.sh", "parse_config_data"),
):
    call = ('unset SECURITY_GATE_AUDIT_DIR LLM_MODEL\nCONFIG_BAD_LINE=0 SG_CONFIG_BAD_LINE=0\n'
            + name + ' "$value" < "$value"; rc=$?\n'
            + 'printf "\\0%s:%s:%s:%s:%s\\0" "$rc" "$CONFIG_BAD_LINE" "$SG_CONFIG_BAD_LINE" "${SECURITY_GATE_AUDIT_DIR-}" "${LLM_MODEL-}"')
    compare(name, production(path, name), [name], paths, call)

override_dir = Path(environment["TRELLIS_HOME"]) / "state/reread-overrides"
override_dir.mkdir(parents=True)
reasons = [b"okay", "é".encode() * 1000, "é".encode() * 1000 + b"x",
           b"\xff" * 2000, b"\xff" * 2001, b"a" * 4096, b"", b"\xc2\x80"]
reasons += [b"x" + bytes([n]) + b"z" for n in range(1, 256)]
keys = []
for n, reason in enumerate(reasons, 1):
    key = f"{n:016x}"
    (override_dir / key).write_bytes(b"1700000300\t1699999700\t" + reason + b"\n")
    keys.append(key.encode())
keys += [b"missing", b"a" * 15, b"a" * 17, b"A" * 16, b"\xff" * 16]
compare("_gr_reread_override_active",
        production("scripts/lib/guard-rules-runtime.bash", "_gr_trellis_home", "_gr_reread_override_active"),
        ["_gr_trellis_home", "_gr_reread_override_active"], keys,
        '_gr_reread_override_active "$value"; printf "%s\\0" "$?"',
        'GR_REREAD_OVERRIDE_TTL=600\n_gr_now() { GR_NOW=1700000000; }')

analyze_dir = scratch / "analyze"
analyze_dir.mkdir()
for name in ("analyze.md", "analyze-2.md", "analyze-0003.md", "analyze-99.md",
             "analyze-100000000000000000000000.md", "analyze-K.md", "analyze-٢.md"):
    (analyze_dir / name).write_text("## Verdict: PASS\n", encoding="utf-8")
compare("resolve_analyze_report", production("core-rules/skills/process-gate/scripts/check-analyze.sh", "resolve_analyze_report"),
        ["resolve_analyze_report"], [os.fsencode(analyze_dir)],
        'resolve_analyze_report "$value"; printf "\\0%s\\0" "$?"')

hooks_dir = scratch / "hooks"
hooks_dir.mkdir()
for name in ("pre-commit", "commit-msg", "post-merge", "post-rewrite", "pre-rebase", "update", "é", "K", os.fsdecode(b"\xff")):
    file = hooks_dir / name
    try:
        file.write_text("#!/bin/sh\n", encoding="utf-8")
    except OSError as exc:
        if name == os.fsdecode(b"\xff") and exc.errno == errno.EILSEQ:
            print("invalid-byte filename case unavailable: filesystem rejects it (EILSEQ)")
            continue
        raise
    file.chmod(0o700)
dependency = production("scripts/lib/attachment.sh", "_attachment_hooks_is_passthrough_name")
compare("_attachment_hooks_expected_passthrough_names",
        dependency + production("scripts/lib/attachment.sh", "_attachment_hooks_expected_passthrough_names"),
        ["_attachment_hooks_expected_passthrough_names"], [os.fsencode(hooks_dir)],
        '_attachment_hooks_expected_passthrough_names / "$value"; printf "\\0%s\\0" "$?"',
        dependency)
