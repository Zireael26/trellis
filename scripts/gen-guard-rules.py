#!/usr/bin/env python3
"""Compile core-rules/hooks/rules/*.json into the bash guard include.

Usage (from the repository root):
  python3 -I scripts/gen-guard-rules.py --write   regenerate the include
  python3 -I scripts/gen-guard-rules.py --check   lint the rules; fail on drift

The include is written twice with identical bytes, once per hook tree, because
each tree ships only its own lib/ (core-rules/hooks/lib for Claude,
core-rules/codex/hooks/lib for Codex and pi). It is checked in: a release
payload is the approved release commit minus test paths, so the generated file
has to be in that commit. The hooks suite's guard-rules.bats runs `--check`
in the hooks stage of the battery, so a rule edited without regenerating fails
the gate before any release commit is cut from it.

Every pattern must sit in the common subset of POSIX ERE (bash [[ =~ ]], grep
-E, sed -E) and JavaScript RegExp, so the bash guards and the pi in-process
guard read one rule file and agree. The lint refuses anything outside it.
"""

import argparse
import json
import re
import sys
from pathlib import Path

RULES_DIR = Path("core-rules/hooks/rules")
RUNTIME = Path("scripts/lib/guard-rules-runtime.bash")
OUTPUTS = (Path("core-rules/hooks/lib/guard-rules.sh"), Path("core-rules/codex/hooks/lib/guard-rules.sh"))
ENGINES = ("claude", "codex")

# Outside brackets: the characters that may follow a backslash (each is special
# in both dialects, so the escape means the literal in both), and the
# characters that may not appear bare.
ESCAPABLE = set("^.[$()|*+?{\\")
NOT_BARE = set(".]}")
BRACKET_CONTROLS = set("\t\n\x0b\f\r")


class RuleError(Exception):
    pass


def lint_bracket(pattern, start):
    """Return the index past the bracket expression opening at `start`."""
    i = start + 1
    if pattern[i:i + 1] == "^":
        i += 1
    body_start = i
    while True:
        if i >= len(pattern):
            raise RuleError("unterminated bracket expression")
        c = pattern[i]
        if c == "]":
            if i == body_start:
                raise RuleError("a bracket may not start with ] (POSIX literal, JavaScript empty class)")
            break
        if c == "\\":
            raise RuleError("backslash inside brackets (POSIX literal, JavaScript escape)")
        if c == "[" and pattern[i + 1:i + 2] in (":", ".", "="):
            raise RuleError("POSIX [: :], [. .] and [= =] are not JavaScript; spell the characters out")
        if not (0x20 <= ord(c) < 0x7F or c in BRACKET_CONTROLS):
            raise RuleError(f"character {c!r} inside brackets is outside the subset")
        i += 1
    body = pattern[body_start:i]
    k = 0
    while k < len(body):
        if k + 2 < len(body) and body[k + 1] == "-":
            lo, hi = body[k], body[k + 2]
            same_class = any(
                lo in cls and hi in cls
                for cls in ("0123456789", "abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            )
            if not same_class or lo > hi:
                raise RuleError(f"range {lo}-{hi} must stay within one of 0-9, a-z, A-Z")
            k += 3
        elif body[k] == "-" and 0 < k < len(body) - 1:
            raise RuleError("a literal - inside brackets must come first or last")
        else:
            k += 1
    return i + 1


def lint_pattern(pattern):
    """Tokenize a pattern, refusing anything outside the common subset.

    Returns (kind, text) tokens: atom, open, close, alt, quant, bol, eol.
    """
    if not pattern:
        raise RuleError("empty pattern")
    tokens = []
    depth = 0
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "\\":
            if pattern[i + 1:i + 2] not in ESCAPABLE or i + 1 >= len(pattern):
                raise RuleError("only \\ followed by one of ^.[$()|*+?{\\ is allowed outside brackets")
            tokens.append(("atom", pattern[i:i + 2]))
            i += 2
        elif c == "[":
            end = lint_bracket(pattern, i)
            tokens.append(("atom", pattern[i:end]))
            i = end
        elif c == "(":
            if pattern[i + 1:i + 2] == "?":
                raise RuleError("(? groups are JavaScript-only")
            depth += 1
            tokens.append(("open", c))
            i += 1
        elif c == ")":
            if depth == 0:
                raise RuleError("unbalanced )")
            depth -= 1
            tokens.append(("close", c))
            i += 1
        elif c == "|":
            tokens.append(("alt", c))
            i += 1
        elif c in "*+?":
            tokens.append(("quant", c))
            i += 1
        elif c == "{":
            m = re.match(r"\{([0-9]+)(,([0-9]*))?\}", pattern[i:])
            if not m:
                raise RuleError("{ must open an interval {m}, {m,} or {m,n}; escape a literal {")
            lo = int(m.group(1))
            hi = int(m.group(3)) if m.group(3) else lo
            if (m.group(3) and hi < lo) or max(lo, hi) > 255:
                raise RuleError(f"interval {m.group(0)} is out of order or above 255")
            tokens.append(("quant", m.group(0)))
            i += len(m.group(0))
        elif c == "^":
            tokens.append(("bol", c))
            i += 1
        elif c == "$":
            tokens.append(("eol", c))
            i += 1
        elif c in NOT_BARE:
            hint = "use [^\\n] for any character" if c == "." else "escape it or put it in brackets"
            raise RuleError(f"bare {c!r} is outside the subset; {hint}")
        elif 0x20 <= ord(c) < 0x7F:
            tokens.append(("atom", c))
            i += 1
        else:
            raise RuleError(f"character {c!r} outside brackets is outside the subset")
    if depth:
        raise RuleError("unbalanced (")
    kinds = ["start"] + [kind for kind, _ in tokens] + ["end"]
    for n in range(1, len(kinds) - 1):
        prev, kind, nxt = kinds[n - 1], kinds[n], kinds[n + 1]
        if kind == "quant" and prev not in ("atom", "close"):
            raise RuleError("a quantifier must follow a character, bracket or group (no ** or lazy +?)")
        if kind == "alt" and (prev in ("start", "open", "alt") or nxt in ("end", "close", "alt")):
            raise RuleError("empty alternative")
        if kind == "open" and nxt == "close":
            raise RuleError("empty group")
    return tokens


def check_pattern(pattern, where, ignore_case=False):
    try:
        tokens = lint_pattern(pattern)
    except RuleError as err:
        raise RuleError(f"{where}: {err}: {pattern!r}") from None
    # Inside the subset Python's re agrees with both dialects; it proves the
    # pattern compiles and cannot match an empty line (empty lines are dropped).
    flags = re.ASCII | (re.IGNORECASE if ignore_case else 0)
    if re.compile(pattern, flags).search("") is not None:
        raise RuleError(f"{where}: pattern matches an empty line: {pattern!r}")
    return tokens


def text_pattern(tokens):
    """The pattern with ^ and $ widened to line boundaries (a whole-text prefilter)."""
    out = []
    for kind, text in tokens:
        out.append({"bol": "(^|\n)", "eol": "(\n|$)"}.get(kind, text))
    return "".join(out)


def check_keys(obj, where, required, optional=()):
    if not isinstance(obj, dict):
        raise RuleError(f"{where}: expected an object")
    missing = [k for k in required if k not in obj]
    unknown = [k for k in obj if k not in required and k not in optional]
    if missing or unknown:
        raise RuleError(f"{where}: missing {missing} unknown {unknown}")


def check_text(value, where):
    # jq and json.dumps escape these strings identically only without control
    # characters, so a reason the guard prints reads as jq printed it.
    if not isinstance(value, str) or not value or any(ord(c) < 0x20 or ord(c) == 0x7F for c in value):
        raise RuleError(f"{where}: expected a non-empty one-line string")
    return value


def load_destructive(doc):
    check_keys(doc, "destructive.json", ("schema_version", "guard", "description", "semantics", "rules"))
    if doc["schema_version"] != 1 or doc["guard"] != "block-destructive":
        raise RuleError("destructive.json: schema_version 1, guard block-destructive expected")
    rules, seen = [], set()
    for n, rule in enumerate(doc["rules"]):
        where = f"destructive.json rules[{n}]"
        check_keys(rule, where, ("id", "effect", "match"),
                   ("reason", "message", "message_by_engine", "ignore_case", "unless", "exempt"))
        rid = rule["id"]
        if not re.fullmatch(r"[a-z0-9-]+", rid) or rid in seen:
            raise RuleError(f"{where}: id must be unique lowercase-hyphenated: {rid!r}")
        seen.add(rid)
        where = f"destructive.json {rid}"
        icase = rule.get("ignore_case", False)
        if not isinstance(icase, bool):
            raise RuleError(f"{where}: ignore_case must be a boolean")
        if rule["effect"] == "deny":
            if "message" in rule or "message_by_engine" in rule:
                raise RuleError(f"{where}: a deny rule has a reason, not a message")
            check_text(rule.get("reason"), f"{where} reason")
        elif rule["effect"] == "warn":
            if "reason" in rule:
                raise RuleError(f"{where}: a warn rule has a message, not a reason")
            check_text(rule.get("message"), f"{where} message")
            for engine, message in rule.get("message_by_engine", {}).items():
                if engine not in ENGINES:
                    raise RuleError(f"{where}: unknown engine {engine!r}")
                check_text(message, f"{where} message_by_engine.{engine}")
        else:
            raise RuleError(f"{where}: effect must be deny or warn")
        if not rule["match"]:
            raise RuleError(f"{where}: match must list at least one pattern")
        compiled = dict(rule)
        compiled["match"] = [(p, check_pattern(p, f"{where} match", icase)) for p in rule["match"]]
        compiled["unless"] = [(p, check_pattern(p, f"{where} unless", icase)) for p in rule.get("unless", [])]
        if "exempt" in rule:
            ex = rule["exempt"]
            check_keys(ex, f"{where} exempt", ("engines", "allowed_commands", "command_prefixes",
                                               "refuse_if_line_matches", "refuse_short_flags", "boundaries",
                                               "identifier", "identifier_boundary", "replacement"), ("why",))
            if not ex["engines"] or any(e not in ENGINES for e in ex["engines"]):
                raise RuleError(f"{where} exempt: engines must name {ENGINES}")
            if not ex["allowed_commands"] or \
                    any(not isinstance(c, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+( [A-Za-z0-9_.-]+)*", c)
                        for c in ex["allowed_commands"]) or \
                    any(not isinstance(w, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", w) for w in ex["command_prefixes"]):
                raise RuleError(f"{where} exempt: allowed_commands are plain words separated by one space, "
                                "command_prefixes plain words")
            marks = ex["boundaries"]
            if not re.fullmatch(r"[!-~]+", marks) or len(set(marks)) != len(marks):
                raise RuleError(f"{where} exempt: boundaries are distinct printable characters")
            check_text(ex["replacement"], f"{where} exempt replacement")
            if not re.fullmatch(r"[!-~]+", ex["replacement"]) or "/" in ex["replacement"]:
                raise RuleError(f"{where} exempt: replacement is printable ASCII without /")
            check_pattern(ex["identifier"], f"{where} exempt identifier", icase)
            tokens = lint_pattern(ex["identifier_boundary"])
            if len(tokens) != 1 or not ex["identifier_boundary"].startswith("["):
                raise RuleError(f"{where} exempt: identifier_boundary must be one bracket expression")
            if any(not re.fullmatch(r"-[A-Za-z0-9]", x) for x in ex["refuse_short_flags"]):
                raise RuleError(f"{where} exempt refuse_short_flags: -x flags")
            refuse = [(pat, check_pattern(pat, f"{where} exempt refuse_if_line_matches", icase))
                      for pat in ex["refuse_if_line_matches"]]
            compiled["exempt"] = dict(ex, regex=f"({ex['identifier_boundary']})({ex['identifier']})", refuse=refuse)
        rules.append(compiled)
    return rules


def load_reread(doc):
    check_keys(doc, "reread.json", ("schema_version", "guard", "description", "warn_budget", "messages",
                                    "edit_failure_markers"))
    if doc["schema_version"] != 1 or doc["guard"] != "reread-guard":
        raise RuleError("reread.json: schema_version 1, guard reread-guard expected")
    budget = doc["warn_budget"]
    check_keys(budget, "reread.json warn_budget", ("default", "by_level"))
    # The block fires at every autonomy level; a budget of 0 would skip the
    # warns that must precede it (locked decision #2).
    values = [budget["default"], *budget["by_level"].values()]
    if any(not isinstance(v, int) or isinstance(v, bool) or v < 1 for v in values) or \
            any(k not in ("1", "2", "3", "4", "5") for k in budget["by_level"]):
        raise RuleError("reread.json warn_budget: levels 1-5, budgets of at least 1")
    messages = doc["messages"]
    check_keys(messages, "reread.json messages", ("warn", "block"))
    for name, allowed in (("warn", {"path", "count", "budget"}), ("block", {"path"})):
        check_text(messages[name], f"reread.json messages.{name}")
        used = set(re.findall(r"\{([a-z]+)\}", messages[name]))
        if used - allowed or "path" not in used or re.sub(r"\{[a-z]+\}", "", messages[name]).count("{"):
            raise RuleError(f"reread.json messages.{name}: placeholders are {sorted(allowed)}")
    markers = doc["edit_failure_markers"]
    check_keys(markers, "reread.json edit_failure_markers", ("ignore_case", "pattern"), ("why",))
    if not isinstance(markers["ignore_case"], bool):
        raise RuleError("reread.json edit_failure_markers: ignore_case must be a boolean")
    tokens = check_pattern(markers["pattern"], "reread.json edit_failure_markers", markers["ignore_case"])
    return {"budget": budget, "messages": messages, "markers": markers, "marker_tokens": tokens}


def sh(value):
    """A bash word that expands to exactly `value`."""
    # A single-quoted word ending in a backslash is correct but reads as a
    # mistaken escape (shellcheck SC1003), so it takes the $'...' form.
    if all(0x20 <= ord(c) < 0x7F for c in value) and "'" not in value and not value.endswith("\\"):
        return f"'{value}'"
    named = {"\\": "\\\\", "'": "\\'", "\t": "\\t", "\n": "\\n", "\x0b": "\\v", "\f": "\\f", "\r": "\\r"}
    out = []
    for c in value:
        if c in named:
            out.append(named[c])
        elif ord(c) < 0x20 or ord(c) == 0x7F:
            out.append(f"\\x{ord(c):02x}")
        else:
            out.append(c)
    return "$'" + "".join(out) + "'"


def sh_template(template, args):
    """A bash word for `template` with each {name} replaced by its positional parameter."""
    parts = re.split(r"\{([a-z]+)\}", template)
    out = []
    for n, part in enumerate(parts):
        if n % 2:
            out.append(f'"${args[part]}"')
        elif part:
            out.append(sh(part))
    return "".join(out)


def match_call(pattern, tokens):
    return f"_gr_m {sh(pattern)} {sh(text_pattern(tokens))}"


def engine_test(engines):
    if len(engines) == 1:
        return f'[ "$1" = {engines[0]} ]'
    return f'case $1 in {"|".join(engines)}) true ;; *) false ;; esac'


def render_destructive(rules):
    out = [
        "# _gr_destructive <claude|codex> <command>",
        "#   Applies rules/destructive.json. Prints each firing warn rule's message to",
        "#   stderr. Succeeds when a deny rule fires, with GR_DENY_ID, GR_DENY_REASON and",
        "#   GR_DENY_JSON (the reason as a JSON string literal) set.",
        "_gr_destructive() {",
        "  GR_DENY_ID='' GR_DENY_REASON='' GR_DENY_JSON=''",
        "  _gr_with_rules _gr_destructive_rules \"$@\"",
        "}",
        "",
        "_gr_destructive_rules() {",
        "  _gr_lines_of \"$2\"",
    ]
    icase = False
    for n, rule in enumerate(rules):
        out.append(f"  # {rule['id']}")
        if rule.get("ignore_case", False) != icase:
            icase = not icase
            out.append(f"  _gr_icase {int(icase)}")
        exempt = rule.get("exempt")
        if exempt:
            out += [
                f"  if {' && '.join([engine_test(exempt['engines'])] + [f'! {match_call(p, t)}' for p, t in exempt['refuse']])}; then",
                f"    _gr_exempt {sh(','.join(exempt['allowed_commands']))} {sh(' '.join(exempt['command_prefixes']))} \\",
                f"      {sh(exempt['boundaries'])} {sh(exempt['regex'])} {sh(exempt['replacement'])} \\",
                f"      {sh(' '.join(exempt['refuse_short_flags']))}",
                "  fi",
            ]
        cond = " && ".join([match_call(p, t) for p, t in rule["match"]] +
                           [f"! {match_call(p, t)}" for p, t in rule["unless"]])
        out.append(f"  if {cond}; then")
        if rule["effect"] == "deny":
            out += [
                f"    GR_DENY_ID={rule['id']}",
                f"    GR_DENY_REASON={sh(rule['reason'])}",
                f"    GR_DENY_JSON={sh(json.dumps(rule['reason'], ensure_ascii=False))}",
                "    return 0",
            ]
        else:
            by_engine = rule.get("message_by_engine", {})
            if by_engine:
                first = True
                for engine, message in by_engine.items():
                    out.append(f"    {'if' if first else 'elif'} [ \"$1\" = {engine} ]; then")
                    out.append(f"      printf '%s\\n' {sh(message)} >&2")
                    first = False
                out += ["    else", f"      printf '%s\\n' {sh(rule['message'])} >&2", "    fi"]
            else:
                out.append(f"    printf '%s\\n' {sh(rule['message'])} >&2")
        out.append("  fi")
        if exempt and n + 1 < len(rules):
            out.append("  _gr_lines_of \"$2\"")
    out += ["  return 1", "}"]
    return out


def render_reread(reread):
    budget = reread["budget"]
    by_value = {}
    for level, value in sorted(budget["by_level"].items()):
        by_value.setdefault(value, []).append(level)
    markers = reread["markers"]
    out = [
        "# _gr_reread_budget <autonomy-level> — GR_BUDGET = warns allowed before a block.",
        "_gr_reread_budget() {",
        "  case $1 in",
    ]
    for value, levels in by_value.items():
        out.append(f"    {'|'.join(levels)}) GR_BUDGET={value} ;;")
    out += [
        f"    *) GR_BUDGET={budget['default']} ;;",
        "  esac",
        "}",
        "",
        "# _gr_reread_warn_msg <path> <count> <budget> — GR_MSG = the warn advisory.",
        "_gr_reread_warn_msg() {",
        f"  GR_MSG={sh_template(reread['messages']['warn'], {'path': 1, 'count': 2, 'budget': 3})}",
        "}",
        "",
        "# _gr_reread_block_msg <path> — GR_MSG = the block reason.",
        "_gr_reread_block_msg() {",
        f"  GR_MSG={sh_template(reread['messages']['block'], {'path': 1})}",
        "}",
        "",
        "# Edit-family error-string markers. The Codex guards hand these to jq's",
        "# test(GR_EDIT_FAILURE_RE; GR_EDIT_FAILURE_FLAGS); _gr_edit_failed tests them here.",
        f"GR_EDIT_FAILURE_RE={sh(markers['pattern'])}",
        f"GR_EDIT_FAILURE_FLAGS={'i' if markers['ignore_case'] else ''}",
        "",
        "# _gr_edit_failed <response> — the response carries an edit-failure marker.",
        "_gr_edit_failed() {",
        "  _gr_with_rules _gr_edit_failed_rules \"$1\"",
        "}",
        "",
        "_gr_edit_failed_rules() {",
        "  _gr_lines_of \"$1\"",
        f"  _gr_icase {int(markers['ignore_case'])}",
        f"  {match_call(markers['pattern'], reread['marker_tokens'])}",
        "}",
    ]
    return out


def render(root):
    destructive = load_destructive(json.loads((root / RULES_DIR / "destructive.json").read_text()))
    reread = load_reread(json.loads((root / RULES_DIR / "reread.json").read_text()))
    runtime = (root / RUNTIME).read_text().splitlines()
    if runtime and runtime[0] == "# shellcheck shell=bash":
        runtime = runtime[1:]
    lines = [
        "#!/usr/bin/env bash",
        "# guard-rules.sh — GENERATED from core-rules/hooks/rules/*.json and",
        "# scripts/lib/guard-rules-runtime.bash by scripts/gen-guard-rules.py.",
        "# Do not edit. Change the JSON or the runtime, then run",
        "#   python3 -I scripts/gen-guard-rules.py --write",
        "# and commit the result; --check (guard-rules.bats) fails on drift.",
        "#",
        "# Sourced by block-destructive.sh, reread-guard.sh and track-read.sh in both",
        "# hook trees. Sourcing defines functions and constants only.",
        "",
        *runtime,
        "",
        "# --- rules/destructive.json " + "-" * 50,
        "",
        *render_destructive(destructive),
        "",
        "# --- rules/reread.json " + "-" * 55,
        "",
        *render_reread(reread),
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="lint the rules and fail when the include is stale")
    mode.add_argument("--write", action="store_true", help="regenerate the include")
    parser.add_argument("--root", type=Path, default=Path("."), help="repository root (default: .)")
    args = parser.parse_args()
    try:
        text = render(args.root)
    except (RuleError, json.JSONDecodeError, OSError) as err:
        print(f"gen-guard-rules: {err}", file=sys.stderr)
        return 1
    stale = []
    for out in OUTPUTS:
        path = args.root / out
        if args.write:
            path.write_text(text)
        elif not path.is_file() or path.read_text() != text:
            stale.append(str(out))
    if stale:
        print(f"gen-guard-rules: stale against core-rules/hooks/rules/: {', '.join(stale)}; "
              "run python3 -I scripts/gen-guard-rules.py --write and commit the result", file=sys.stderr)
        return 1
    print("gen-guard-rules: " + ("wrote " + ", ".join(map(str, OUTPUTS)) if args.write else "OK"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
