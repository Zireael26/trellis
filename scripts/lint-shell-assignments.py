#!/usr/bin/env python3
"""Guard temporary shell assignments in redirected command substitutions.

The shell tree comes from lint-shell-tree.sh, not a second suffix-only walk.
A finding is a simple command with one or more shell assignment prefixes and
an actual command word inside $(...) or backticks, where a redirection appears
in that substitution (or an enclosing substitution), or on the containing
outer simple command. A redirect on an unrelated pipeline member still counts:
this deliberately conservative rule also covers redirected compound commands.
`env NAME=value command` is not a shell assignment prefix.
Locale declarations (local/declare/typeset/readonly, including bare names but not
-p/-f/-F queries) are rejected everywhere, even outside
substitutions. The migrated helpers below reject ALL in-shell locale assignments:
Bash 5.3 can crash on runtime locale changes after fork, including save/restore.
Use locale-independent byte tests or `env LC_ALL=C command` instead. The only
declaration exception is the exact native-pinned semver.sh digest and command;
that native input awaits a rebuild. The exact _gr_with_rules bodies also retain
C-locale regex/nocasematch semantics pending native-path work, without adding a
subprocess on every tool call. Other legacy assignments retain the existing
redirected-substitution rule (see docs/evidence/153-locale-local.md).

This is a bounded lexical scanner, NOT a Bash parser or an execution proof.
It handles ordinary quoting/escapes/comments, multiline and nested expansions,
pipelines, redirection operands, arithmetic and process substitutions. It scans
active expansions in unquoted heredocs and also scans generated shell heredocs
whose body starts with a shell shebang, whose consumer is a literal shell, or
whose command line names a .sh/.bash output. A multi-heredoc dispatcher such
as scripts/lib/attachment.sh has only its shebang-bearing first chunk covered;
later quoted chunks are not recognized merely because they continue it. Strings
later passed to eval/bash -c, aliases, complex case-pattern/backtick syntax,
Bash 5.3's ${ command; } substitutions, and dynamically constructed source
cannot be classified reliably. The scanner does not follow function calls: an
assignment inside a function called from a substitution is not linked to its
caller's redirections. Review these manually; a clean result is not a proof.

The shared tree includes .sh/.bash tests and fixtures, plus extensionless shell
shebangs, but not .bats files or doctor-fix-common.bash; core-rules/evals and
.claude/worktrees are pruned. --list itself only lists that tree and needs
neither this scanner nor the baseline.

Baseline fingerprints hash the exact command and its exact enclosing evidence,
paired with the owning relative path. Line numbers are informational only.
Identical hits in the same path share a count: moving an identical hit within
that file is indistinguishable. Stale allowances fail as well as new hits, so
removing a hit requires pruning the baseline and cannot leave a reusable slot.

From the repository root, AFTER reviewing the working tree and pending edits:
  bash scripts/lint-shell-tree.sh --write-assignment-baseline
Then inspect the JSON diff; never mechanically accept new non-locale hits. The
writer never baselines LANG, LANGUAGE or LC_* prefix assignments: it writes the
non-locale inventory but exits nonzero while any locale hit remains. Both read
and write modes fail on unreadable input; ordinary lint also fails on a missing,
malformed, inconsistent, locale-containing, or unreadable baseline.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys

ASSIGNMENT = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)(?:\[[^]\n]+\])?\+?=")
REDIRECT = re.compile(r"(?:[0-9]+|\{[a-zA-Z_][a-zA-Z0-9_]*\})?(?:<<<|<<-|<<|<>|<&|>>|>&|>\||>|<)|&>>|&>")
SHELL_CONSUMER = re.compile(r"(?:^|[\s;|&])(?:[^\s;|&]*/)?(?:ba|da|k)?sh(?:\s|$)")
SHELL_OUTPUT = re.compile(r"(?:^|[\s>'\"])[^\s]*\.(?:bash|sh)(?:[\s'\"]|$)")
SHELL_SHEBANG = re.compile(r"^#![^\n]*\b(?:bash|dash|ksh|sh)(?:\s|$)")
PREFIX_KEYWORDS = {"if", "elif", "while", "until", "then", "do", "else", "!", "time"}
MIGRATED_LOCALE_HELPERS = {
    "trellis_home_has_unsafe_chars", "trellis_home_native_entry_path_is_safe",
    "_attachment_visible", "_attachment_hooks_expected_passthrough_names",
    "shared_infra_safe_line", "_gr_json_str",
    "_gr_reread_override_active", "pg_audit_dir_values", "resolve_analyze_report",
    "sg_parse_local_config", "parse_config_data",
}
PINNED_SEMVER_SHA256 = "94c8ae45918a99490575014c7930b8bb22196c1ab6c839e229c7d2222eab2f82"
# C-locale regex/nocasematch semantics; native follow-up, not per-tool forks.
PINNED_RULE_MATCHER_SHA256 = "d17f5213dc807baf6494c6e9abfef048dec8cfb23af128cc282a72fa868d0468"
RULE_MATCHER_PATHS = {
    "scripts/lib/guard-rules-runtime.bash", "core-rules/hooks/lib/guard-rules.sh",
    "core-rules/codex/hooks/lib/guard-rules.sh",
}


class Token:
    def __init__(self, kind, start, end, text):
        self.kind, self.start, self.end, self.text = kind, start, end, text
        self.children = []
        self.command = None


class Command:
    def __init__(self, tokens):
        self.tokens = tokens
        self.start, self.end = tokens[0].start, tokens[-1].end
        self.redirects = [t for t in tokens if t.kind == "redirect"]
        for token in tokens:
            token.command = self

    def assignments(self):
        # Redirections can precede or interleave the assignment words. Their
        # operands are not command words. env/command/builtin are command words.
        prefixes = []
        skip_operand = False
        beginning = True
        for token in self.tokens:
            if token.kind == "redirect":
                skip_operand = True
                continue
            if skip_operand:
                skip_operand = False
                continue
            if beginning and token.text in PREFIX_KEYWORDS:
                continue
            beginning = False
            match = ASSIGNMENT.match(token.text)
            if match:
                prefixes.append(match.group(1))
                continue
            return prefixes
        return []  # assignment-only statements are not temporary commands

    def locale_assignments(self, declarations_only=False):
        words = []
        skip_operand = False
        for token in self.tokens:
            if token.kind == "redirect":
                skip_operand = True
            elif skip_operand:
                skip_operand = False
            else:
                words.append(Scanner.delimiter(token.text)[0])
        while words and (words[0] in PREFIX_KEYWORDS or words[0] in {"builtin", "command"}
                         or words[0] in {"--", "-p"}):
            words.pop(0)
        prefixes = []
        while words and ASSIGNMENT.match(words[0]):
            prefixes.append(words.pop(0))
        declaration = words and words[0] in {"local", "declare", "typeset", "readonly"}
        if declaration:
            # Queries do not create a local or mutate its value/attributes.
            for word in words[1:]:
                if word == "--" or not word.startswith(("-", "+")):
                    break
                if set(word[1:]) & {"p", "f", "F"}:
                    return []
        if declarations_only:
            candidates = words[1:] if declaration else []
        else:
            candidates = prefixes + (words[1:] if declaration or (words and words[0] in {"export", "readonly"}) else [])
        names = []
        for word in candidates:
            match = ASSIGNMENT.match(word)
            name = match[1] if match else (word if declaration and re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]*", word) else "")
            if name in {"LANG", "LANGUAGE"} or name.startswith("LC_"):
                names.append(name)
        return names


class Frame:
    def __init__(self, start, parent=None, parent_token=None, substitution=False):
        self.start, self.end = start, start
        self.parent, self.parent_token, self.substitution = parent, parent_token, substitution
        self.commands = []

    def redirected(self):
        return any(command.redirects for command in self.commands)


class Scanner:
    def __init__(self, text):
        self.text = text
        self.frames = []
        # These production helpers use column-zero function boundaries, not
        # nested definitions. This remains a bounded lexical guard, not a parser.
        self.locale_regions = []
        self.locale_helper_names = set()
        header = r"(?m)^([a-zA-Z_][a-zA-Z0-9_]*)[ \t]*\([ \t]*\)[ \t]*([({])[ \t]*(?:#[^\n]*)?\n"
        for match in re.finditer(header, text):
            if match[1] in MIGRATED_LOCALE_HELPERS:
                closing = "}" if match[2] == "{" else ")"
                end = re.search(r"(?m)^" + re.escape(closing) + r"(?=[ \t]*(?:$|#))", text[match.end():])
                if end:
                    self.locale_regions.append((match.start(), match.end() + end.end()))
                    self.locale_helper_names.add(match[1])

    def nested(self, start, limit, parent, token, kind):
        frame = Frame(start, parent, token, True)
        self.frames.append(frame)
        token.children.append(frame)
        end = self.script(start + (2 if kind == "$(" else 1), limit, frame,
                          ")" if kind == "$(" else "`")
        frame.end = end
        return end

    def math(self, i, limit, frame, token):
        # Skip arithmetic operators (not redirects); nested command expansions
        # inside arithmetic are still executed and must be scanned.
        i += 3
        depth = 2
        while i < limit and depth:
            c = self.text[i]
            if c == "\\":
                i += 2
            elif self.text.startswith("$(", i) and not self.text.startswith("$((", i):
                i = self.nested(i, limit, frame, token, "$(")
            elif self.text.startswith("$((", i):
                i = self.math(i, limit, frame, token)
            elif c == "`":
                i = self.nested(i, limit, frame, token, "`")
            elif c in "'\"":
                i = self.quoted(i, limit, frame, token, c)
            else:
                depth += (c == "(") - (c == ")")
                i += 1
        return i

    def parameter(self, i, limit, frame, token):
        i += 2
        while i < limit:
            c = self.text[i]
            if c == "}":
                return i + 1
            if c == "\\":
                i += 2
            elif c in "'\"":
                i = self.quoted(i, limit, frame, token, c)
            else:
                i = self.expansion(i, limit, frame, token)
        return i

    def expansion(self, i, limit, frame, token):
        if self.text.startswith("$((", i):
            return self.math(i, limit, frame, token)
        if self.text.startswith("$(", i):
            return self.nested(i, limit, frame, token, "$(")
        if self.text.startswith("${", i):
            return self.parameter(i, limit, frame, token)
        if self.text[i] == "`":
            return self.nested(i, limit, frame, token, "`")
        return i + 1

    def quoted(self, i, limit, frame, token, quote):
        i += 1
        while i < limit:
            c = self.text[i]
            if c == quote:
                return i + 1
            if quote == "'":
                i += 1
            elif c == "\\" and i + 1 < limit and self.text[i + 1] in '$`"\\\n':
                i += 2
            else:
                i = self.expansion(i, limit, frame, token)
        return i

    def word(self, i, limit, frame, stop):
        start = i
        token = Token("word", start, start, "")
        while i < limit:
            c = self.text[i]
            if stop == "`" and c == "`":
                break
            if c == "\\":
                i = min(i + 2, limit)
            elif c == "$" and i + 1 < limit and self.text[i + 1] == "'":
                # ANSI-C quotes allow backslash-escaped single quotes.
                i += 2
                while i < limit:
                    if self.text[i] == "\\":
                        i += 2
                    elif self.text[i] == "'":
                        i += 1
                        break
                    else:
                        i += 1
            elif c in "'\"":
                i = self.quoted(i, limit, frame, token, c)
            elif self.text.startswith(("<(", ">("), i):
                # Process substitution is not itself $(...), but it can contain
                # nested command substitutions and can occur inside one.
                child = Frame(i, frame, token, False)
                self.frames.append(child)
                token.children.append(child)
                i = self.script(i + 2, limit, child, ")")
                child.end = i
            elif c in " \t\r\n;|&()<>":
                break
            else:
                i = self.expansion(i, limit, frame, token)
        token.end, token.text = i, self.text[start:i]
        return token, i

    @staticmethod
    def delimiter(word):
        # Quote removal for ordinary literal heredoc delimiters.
        output, quoted, quote, i = [], False, None, 0
        while i < len(word):
            c = word[i]
            if c == "\\" and quote != "'" and i + 1 < len(word):
                quoted = True
                output.append(word[i + 1])
                i += 2
            elif c in "'\"" and (quote is None or quote == c):
                quoted = True
                quote = None if quote else c
                i += 1
            else:
                output.append(c)
                i += 1
        return "".join(output), quoted

    def expansions_in_heredoc(self, start, end, frame, parent_token):
        # An unquoted heredoc is not ordinary shell syntax: quote and comment
        # characters are literal, while \$, \` and \\ suppress expansion.
        i = start
        while i < end:
            if self.text[i] == "\\" and i + 1 < end and self.text[i + 1] in "$`\\\n":
                i += 2
            else:
                i = self.expansion(i, end, frame, parent_token)

    def heredocs(self, i, limit, frame, pending):
        for redirect, delimiter, quoted, strip_tabs in pending:
            body_start = i
            while i < limit:
                line_end = self.text.find("\n", i, limit)
                if line_end < 0:
                    line_end = limit
                line = self.text[i:line_end]
                if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                    body_end = i
                    i = min(line_end + 1, limit)
                    break
                i = min(line_end + 1, limit)
            else:
                # Treat the remainder as a body, not as shell code. ShellCheck
                # separately diagnoses malformed input.
                body_end = limit
            parent_token = Token("word", body_start, body_end, "")
            parent_token.command = redirect.command
            if not quoted:
                self.expansions_in_heredoc(body_start, body_end, frame, parent_token)
            line_start = self.text.rfind("\n", 0, redirect.start) + 1
            line_end = self.text.find("\n", redirect.end, limit)
            if line_end < 0:
                line_end = limit
            command_line = self.text[line_start:line_end]
            body = self.text[body_start:body_end]
            if (SHELL_SHEBANG.match(body) or SHELL_CONSUMER.search(command_line)
                    or SHELL_OUTPUT.search(command_line)):
                generated = Frame(body_start)
                self.frames.append(generated)
                self.script(body_start, body_end, generated, None)
                generated.end = body_end
        return i

    def script(self, i, limit, frame, stop):
        current, pending = [], []
        expect_heredoc = None
        parens = 0
        # Minimal case-pattern tracking prevents a pattern's ')' being mistaken
        # for the closing ')' of a surrounding command substitution.
        cases = []

        def finish():
            if current:
                frame.commands.append(Command(current[:]))
                current.clear()

        while i < limit:
            c = self.text[i]
            if c in " \t\r":
                i += 1
                continue
            if c == "\\" and i + 1 < limit and self.text[i + 1] == "\n":
                i += 2
                continue
            if c == "#":
                newline = self.text.find("\n", i, limit)
                i = newline if newline >= 0 else limit
                continue
            if c == "\n":
                finish()
                i += 1
                if pending:
                    i = self.heredocs(i, limit, frame, pending)
                    pending = []
                continue
            if stop == "`" and c == "`":
                finish()
                return i + 1
            if c == ")":
                finish()
                if cases and cases[-1] == "pattern":
                    cases[-1] = "body"
                elif parens:
                    parens -= 1
                elif stop == ")":
                    return i + 1
                i += 1
                continue
            if c == "(":
                finish()
                if not cases or cases[-1] != "pattern":
                    parens += 1
                i += 1
                continue
            if c in "{}" and (i + 1 == limit or self.text[i + 1] in " \t\r\n;|&()"):
                finish()
                i += 1
                continue
            if self.text.startswith(("<(", ">("), i):
                token, i = self.word(i, limit, frame, stop)
            else:
                match = REDIRECT.match(self.text, i)
                if match:
                    token = Token("redirect", i, match.end(), match.group())
                    i = match.end()
                    current.append(token)
                    # <<< is a here-string, not a heredoc; treating it as
                    # one would consume the rest of the file as a body.
                    if token.text.endswith("<<-") or (token.text.endswith("<<") and not token.text.endswith("<<<")):
                        expect_heredoc = token
                    continue
                if c in ";|&":
                    op = next((op for op in (";;&", ";;", ";&", "&&", "||", "|&")
                               if self.text.startswith(op, i)), c)
                    finish()
                    if op in (";;", ";&", ";;&") and cases:
                        cases[-1] = "pattern"
                    i += len(op)
                    continue
                token, i = self.word(i, limit, frame, stop)
            if token.start == token.end:
                # Defensive progress on unsupported grammar.
                i += 1
                continue
            if expect_heredoc is not None:
                delimiter, quoted = self.delimiter(token.text)
                pending.append((expect_heredoc, delimiter, quoted,
                                expect_heredoc.text.endswith("<<-")))
                expect_heredoc = None
            elif token.text == "case" and not current:
                cases.append("in")
            elif token.text == "in" and cases and cases[-1] == "in":
                cases[-1] = "pattern"
            elif token.text == "esac" and cases:
                cases.pop()
            current.append(token)
        finish()
        if pending:
            self.heredocs(i, limit, frame, pending)
        return i

    def findings(self):
        root = Frame(0)
        self.frames.append(root)
        self.script(0, len(self.text), root, None)
        root.end = len(self.text)
        found = {}
        for frame in self.frames:
            for command in frame.commands:
                protected = any(start <= command.start < end for start, end in self.locale_regions)
                names = command.locale_assignments(declarations_only=not protected)
                if names:
                    evidence = self.text[command.start:command.end]
                    found[(command.start, command.end)] = {
                        "line": self.text.count("\n", 0, command.start) + 1,
                        "command": evidence, "context": evidence,
                        "assignments": names, "locale": True,
                    }
            # A process substitution within $(...) remains in that substitution;
            # one outside does not itself qualify as command substitution.
            ancestors = []
            cursor = frame
            while cursor is not None:
                ancestors.append(cursor)
                cursor = cursor.parent
            if not any(item.substitution for item in ancestors):
                continue
            context = next((item for index, item in enumerate(ancestors)
                            if item.redirected() and any(parent.substitution for parent in ancestors[index:])), None)
            external = None
            if context is None:
                for item in ancestors:
                    if item.parent_token is not None and item.parent_token.command is not None:
                        command = item.parent_token.command
                        if command.redirects:
                            external = command
                            break
            if context is None and external is None:
                continue
            context_start = context.start if context else external.start
            context_end = context.end if context else external.end
            for command in frame.commands:
                names = command.assignments()
                if not names:
                    continue
                key = (command.start, command.end)
                prior = found.get(key)
                names = list(dict.fromkeys(names + (prior["assignments"] if prior else [])))
                found[key] = {
                    "line": self.text.count("\n", 0, command.start) + 1,
                    "command": self.text[command.start:command.end],
                    "context": self.text[context_start:context_end],
                    "assignments": names,
                    "locale": any(name in ("LANG", "LANGUAGE") or name.startswith("LC_")
                                  for name in names),
                }
        return list(found.values())


def fingerprint(command, context):
    data = json.dumps([command, context], ensure_ascii=True, separators=(",", ":"))
    return hashlib.sha256(data.encode("ascii")).hexdigest()


def inventory(paths):
    entries = {}
    for name in paths:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or str(path) != name:
            raise ValueError(f"not a normalized relative path: {name!r}")
        raw = path.read_bytes()
        text = raw.decode("utf-8", "surrogateescape")
        for hit in Scanner(text).findings():
            # Two exact declarations in a native include_bytes! input. No new
            # bytes, command, path or general locale baseline inherits this slot.
            if (name == "scripts/lib/semver.sh"
                    and hashlib.sha256(raw).hexdigest() == PINNED_SEMVER_SHA256
                    and hit["command"] == 'local left="$1" right="$2" LC_ALL=C'
                    and hit["assignments"] == ["LC_ALL"]):
                continue
            if (name in RULE_MATCHER_PATHS
                    and hit["command"] == "local LC_ALL=C _gr_text='' nocase=0 rc"
                    and hit["assignments"] == ["LC_ALL"]):
                matcher = re.search(r"(?ms)^_gr_with_rules\(\) \{\n.*?^\}", text)
                if (matcher and text.count("\n", 0, matcher.start()) + 1 <= hit["line"]
                        < text.count("\n", 0, matcher.end()) + 1
                        and hashlib.sha256(matcher[0].encode("utf-8", "surrogateescape")).hexdigest()
                        == PINNED_RULE_MATCHER_SHA256):
                    continue
            key = (name, fingerprint(hit["command"], hit["context"]))
            if key not in entries:
                entries[key] = {"path": name, "sha256": key[1], "count": 0,
                                "example_line": hit["line"], "command": hit["command"],
                                "context": hit["context"], "assignments": hit["assignments"],
                                "locale": hit["locale"]}
            entries[key]["count"] += 1
    return entries


def load_paths(path):
    data = sys.stdin.buffer.read() if path == "-" else Path(path).read_bytes()
    if not data or not data.endswith(b"\0"):
        raise ValueError("shell inventory must be nonempty and NUL-terminated")
    names = [os.fsdecode(item) for item in data[:-1].split(b"\0")]
    if any(not item for item in names) or len(set(names)) != len(names):
        raise ValueError("shell inventory contains empty or duplicate paths")
    return sorted(names)


def load_baseline(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if (not isinstance(data, dict) or type(data.get("schema_version")) is not int
            or data["schema_version"] != 1 or not isinstance(data.get("entries"), list)):
        raise ValueError("invalid baseline schema")
    entries = {}
    for row in data["entries"]:
        if not isinstance(row, dict) or set(row) != {"path", "sha256", "count", "example_line", "command", "context", "assignments"}:
            raise ValueError("invalid baseline entry fields")
        if (not all(isinstance(row[key], str) for key in ("path", "sha256", "command", "context"))
                or type(row["count"]) is not int or row["count"] < 1
                or type(row["example_line"]) is not int or row["example_line"] < 1
                or not row["path"] or Path(row["path"]).is_absolute() or ".." in Path(row["path"]).parts
                or not isinstance(row["assignments"], list) or not row["assignments"]
                or not all(isinstance(name, str) and re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]*", name)
                           for name in row["assignments"])
                or fingerprint(row["command"], row["context"]) != row["sha256"]):
            raise ValueError("invalid baseline entry values or fingerprint")
        # Never accept locale-prefix hits even in a hand-edited baseline. Actual
        # hits are independently checked against this metadata during comparison.
        if any(name in ("LANG", "LANGUAGE") or name.startswith("LC_") for name in row["assignments"]):
            raise ValueError("locale assignment in baseline")
        key = (row["path"], row["sha256"])
        if key in entries:
            raise ValueError("duplicate baseline entry")
        entries[key] = row
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--files0-from", required=True, help="NUL-delimited shell tree, or - for stdin")
    parser.add_argument("--baseline", required=True, help="baseline JSON path")
    parser.add_argument("--write-baseline", action="store_true", help="replace baseline with reviewed non-locale inventory")
    args = parser.parse_args()
    try:
        paths = load_paths(args.files0_from)
        # Load before scanning: a missing or corrupt inventory cannot pass even
        # if the current tree happens to contain no hits.
        baseline = {} if args.write_baseline else load_baseline(args.baseline)
        hits = inventory(paths)
        if args.write_baseline:
            rows = [{key: value for key, value in row.items() if key != "locale"}
                    for _, row in sorted(hits.items()) if not row["locale"]]
            Path(args.baseline).write_text(json.dumps({"schema_version": 1, "entries": rows},
                                                      indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
            print(f"wrote {len(rows)} fingerprint(s), {sum(row['count'] for row in rows)} occurrence(s) to {args.baseline}; review the diff")
            locale = [row for row in hits.values() if row["locale"]]
            for row in locale:
                print(f"unbaselined locale hit {row['path']}:{row['example_line']}: {row['command']}", file=sys.stderr)
            return 1 if locale else 0
        failed = False
        for key in sorted(set(hits) | set(baseline)):
            hit, allowed = hits.get(key), baseline.get(key)
            actual = hit["count"] if hit else 0
            expected = allowed["count"] if allowed else 0
            if (actual != expected or (hit and hit["locale"])
                    or (hit and allowed and hit["assignments"] != allowed["assignments"])):
                failed = True
                row = hit or allowed
                label = "locale" if hit and hit["locale"] else ("new/excess" if actual > expected else "stale")
                print(f"{label}: {row['path']}:{row['example_line']}: count {actual}, baseline {expected}; sha256 {row['sha256']}\n  {row['command']}", file=sys.stderr)
        if failed:
            print("shell assignment guard: remove new hits or review and prune stale baseline entries", file=sys.stderr)
            return 1
        return 0
    except (OSError, UnicodeError, ValueError, RecursionError) as exc:
        print(f"shell assignment guard: cannot read or validate inventory: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
