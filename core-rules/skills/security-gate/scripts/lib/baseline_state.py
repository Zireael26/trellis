"""Baseline completeness: the one schema check every consumer shares.

    baseline_state.py <baseline.json> <display-name>
        prints "<state>\t<Baseline row>"; state is one of
        complete | unknown | incomplete: <reasons> | unreadable
    baseline_state.py --row <Baseline row text>
        prints "baseline-row: accepted" and exits 0 when the row is one a
        diff may pass on (complete, or a pre-1.4.2 baseline of unknown
        completeness); otherwise prints "baseline-row: rejected", exits 1.
        A caller needs both the line and the exit: an empty or truncated
        validator exits 0 having checked nothing.

run-diff.sh and run-redteam.sh classify with it; process-gate's
check-security-diff.sh judges run-diff's Baseline row with it. Run it with
python3 -I: the baseline is repository data.

A baseline written by run-baseline.sh since 1.4.2 records `profile`,
`complete` and `engines`. It is complete only when every one of these holds:
the engine set contains every engine required by its profile plus only
recognized opt-in engines (shellcheck); each recorded engine's status and
exit agree with how run-baseline.sh writes them; not_applicable appears only
where a wrapper can prove it (osv-scanner, exit 3); and `complete` is true.
A baseline with neither `complete` nor `engines` predates 1.4.2: its
completeness is unknown and it keeps its old treatment.
"""
import json
import sys

ENGINES = ("semgrep", "osv-scanner", "gitleaks")
OPTIONAL_ENGINES = ("shellcheck",)
PROFILE_ENGINES = {"web-rag-llm": ("garak",)}
NOT_APPLICABLE_EXIT = {"osv-scanner": 3}
ROW_COMPLETE = "complete — "
ROW_UNKNOWN = "baseline completeness unknown (pre-1.4.2 baseline) — "


def problems(doc):
    found = []
    complete = doc.get("complete")
    if not isinstance(complete, bool):
        found.append("complete is not a boolean")
    profile = doc.get("profile")
    if not isinstance(profile, str) or not profile:
        found.append("no profile")
        profile = ""
    engines = doc.get("engines")
    if not isinstance(engines, dict) or not engines:
        return found + ["no engine record"]
    required = set(ENGINES) | set(PROFILE_ENGINES.get(profile, ()))
    allowed = required | set(OPTIONAL_ENGINES)
    for name in sorted(required - set(engines)):
        found.append(f"{name} missing")
    for name in sorted(set(engines) - allowed):
        found.append(f"{name} not run by profile {profile or '(none)'}")
    for name in sorted(set(engines) & allowed):
        engine = engines[name]
        status = engine.get("status") if isinstance(engine, dict) else None
        code = engine.get("exit") if isinstance(engine, dict) else None
        if isinstance(code, bool) or not isinstance(code, int):
            found.append(f"{name} has no exit")
        elif status == "ok" and code != 0:
            found.append(f"{name} ok with exit {code}")
        elif status == "not_applicable" and NOT_APPLICABLE_EXIT.get(name) != code:
            found.append(f"{name} not_applicable with exit {code}")
        elif status == "failed" and code == 0:
            found.append(f"{name} failed with exit 0")
        elif status == "invalid_output" and code != 0:
            found.append(f"{name} invalid_output with exit {code}")
        elif status not in ("ok", "not_applicable", "failed", "invalid_output"):
            found.append(f"{name} {status if isinstance(status, str) else 'unrecorded'}"[:80])
        elif status in ("failed", "invalid_output"):
            found.append(f"{name} {status}")
    if not found and complete is not True:
        found.append("complete is not true")
    return found


def classify(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return "unreadable"
    if not isinstance(doc, dict):
        return "unreadable"
    if "complete" not in doc and "engines" not in doc:
        return "unknown"
    found = problems(doc)
    if found:
        return "incomplete: " + ", ".join(found)[:200]
    return "complete"


def row(state, name):
    if state == "complete":
        return ROW_COMPLETE + name
    if state == "unknown":
        return ROW_UNKNOWN + name
    if state.startswith("incomplete: "):
        return f"❌ incomplete ({state[len('incomplete: '):]}) — {name}"
    return f"❌ unreadable — {name}"


def main(argv):
    if len(argv) == 3 and argv[1] == "--row":
        value = argv[2]
        if value.startswith("Baseline:"):
            value = value[len("Baseline:"):].lstrip(" ")
        accepted = value.startswith((ROW_COMPLETE, ROW_UNKNOWN))
        print("baseline-row: " + ("accepted" if accepted else "rejected"))
        return 0 if accepted else 1
    if len(argv) != 3:
        print("usage: baseline_state.py <baseline.json> <display-name> | --row <row>", file=sys.stderr)
        return 64
    state = classify(argv[1])
    # The state is spliced into shell, JSON and Markdown; keep it one line.
    state = "".join(ch if ch.isprintable() else "?" for ch in state)
    print(f"{state}\t{row(state, argv[2])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
