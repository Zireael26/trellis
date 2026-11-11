#!/usr/bin/env bash
# settings-hooks-merge.sh — pure, sourceable helper for the settings.json
# .hooks reconcile step that sync-hooks.sh performs after copying hook files.
#
# Purpose: bring a project's .claude/settings.json .hooks wiring up to the
# canonical baseline WITHOUT clobbering project-specific hook blocks. The hook
# *files* are copied by sync-hooks.sh; this reconciles the *wiring* (which event
# arrays reference which commands) so a project that gained a new canonical hook
# (e.g. reread-guard, track-read, spec-gate, stamp-turn) actually gets it
# wired, while a bespoke hook a project added (e.g. a monorepo project's
# check-module-boundary.sh on PreToolUse Edit|Write, or a custom hook appended
# into the single canonical Stop block) survives verbatim.
#
# Granularity is per hook ENTRY, not per block. The canonical Stop/SessionStart
# baselines are SINGLE multi-entry blocks, so the realistic authoring pattern is
# to append a custom hook entry INTO an existing canonical block. A block-level
# "drop the whole block if any command is canonical" rule would silently lose
# that custom entry. Instead: within each project block we drop only the hook
# ENTRIES whose command basename is canonical (the canonical baseline already
# carries those), keep the surviving non-canonical entries, and keep the block
# itself iff at least one entry survived. So:
#   * a block of ONLY canonical entries -> all entries drop -> empty block pruned
#     (the canonical baseline already laid it down).
#   * a block MIXING canonical + novel entries -> canonical entries drop, novel
#     entries survive in their original block/matcher.
#   * a block of ONLY novel entries -> survives verbatim.
# Comparison is by BASENAME (with any trailing args stripped first, so a
# canonical command invoked WITH a flag still matches and is not duplicated) so
# $CLAUDE_PROJECT_DIR/.claude/hooks/x.sh matches canonical x.sh. The basename
# match is case-SENSITIVE (x.sh != X.sh); hook filenames are lowercase by
# convention, so normalizing case is not worth the surface area.
#
# Read/write contract:
#   READS  — the two file paths passed as args (canonical template + project
#            settings.json), via jq only.
#   WRITES — nothing. Prints the merged settings JSON to stdout. Sets no global
#            variables, mutates no shell state, touches no files. The caller
#            (sync-hooks.sh) owns change-detection, DRY_RUN, and the temp-file
#            write. This separation lets the bats suite bind to the pure
#            function.
#   This file intentionally does NOT set `set -euo pipefail`: sourcing it must
#   not alter the caller's / test harness's shell.
#
# Idempotent: the merge rebuilds .hooks from the canonical baseline plus the
# re-derived surviving (non-canonical) project entries every time, so a 2nd run
# on its own output yields byte-identical JSON. On the 2nd pass the canonical
# baseline's own entries are dropped from the "project" side (they ARE canonical)
# and the surviving custom entries are re-derived once and only once, so nothing
# accumulates.

# settings_owned_json OP BASE OWNED_KEYS [TEMPLATE] [BEFORE] [CREATED_PATHS]
# Same strings-only owner schema: event arrays own their positional canonical
# prefix (and each canonical block's hook prefix), never appended project hooks.
# Pure planner: no writes, no basename guesses and no executable discovery.
settings_owned_json() {
  python3 -I - "$@" <<'PY'
import copy, json, sys
from pathlib import Path

op, filename, encoded_keys = sys.argv[1:4]
missing = object()
def require(ok, reason):
    if not ok:
        raise ValueError(reason)
def pairs(items):
    d = {}
    for key, value in items:
        require(key not in d, 'duplicate JSON key'); d[key] = value
    return d
def parse(text):
    return json.loads(text, object_pairs_hook=pairs)
def read(path):
    return parse(Path(path).read_text())
def same(a, b):
    if type(a) is not type(b):
        return False
    if type(a) is dict:
        return set(a) == set(b) and all(same(a[k], b[k]) for k in a)
    if type(a) is list:
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b
def lookup(obj, path):
    for key in path:
        if type(obj) is not dict or key not in obj:
            return missing
        obj = obj[key]
    return obj
def event_path(path):
    return len(path) == 2 and path[0] == 'hooks'
def event_residual(actual, owned):
    require(type(actual) is list and type(owned) is list and len(actual) >= len(owned), 'owned event positions changed')
    residual = []
    for current, expected in zip(actual, owned):
        require(type(current) is dict and type(expected) is dict and 'hooks' in expected, 'invalid owned event block')
        require(type(expected['hooks']) is list and type(current.get('hooks')) is list, 'invalid owned hooks')
        require(all(k in current and same(current[k], v) for k, v in expected.items() if k != 'hooks'), 'owned block position drift')
        hooks = current['hooks']; prefix = expected['hooks']
        require(len(hooks) >= len(prefix) and all(same(a, b) for a, b in zip(hooks, prefix)), 'owned hook position drift')
        require(set(current) == set(expected), 'owned block field drift')
        if len(hooks) > len(prefix):
            block = copy.deepcopy(current); block['hooks'] = block['hooks'][len(prefix):]
            residual.append(block)
    residual.extend(copy.deepcopy(actual[len(owned):]))
    return residual
def restored_event_prefix(before, key):
    # Only bytes equal to the recorded owned canonical prefix may have been
    # restored by adopt-identical. The remainder of a before-image is project
    # residual, never a second restoration source.
    if before is missing:
        return False
    try:
        event_residual(before, key['value'])
    except ValueError:
        return False
    return True
def valid_owned(keys):
    require(type(keys) is list, 'owned keys are not a list')
    seen = []
    for key in keys:
        require(type(key) is dict and set(key) == {'path', 'value'}, 'invalid owned key')
        p = key['path']
        require(type(p) is list and p and all(type(x) is str and x and not any(ord(c) < 32 for c in x) for x in p), 'invalid owned JSON path')
        require(not any(p[:len(old)] == old or old[:len(p)] == p for old in seen), 'overlapping owned JSON paths')
        seen.append(p)
def detail(base, keys):
    result = []
    for key in keys:
        p, expected = key['path'], key['value']; actual = lookup(base, p)
        if actual is missing:
            result.append({'path': p, 'state': 'missing'})
        else:
            try:
                if event_path(p):
                    event_residual(actual, expected)
                else:
                    require(same(actual, expected), 'owned value changed')
            except ValueError:
                result.append({'path': p, 'state': 'changed'})
    return sorted(result, key=lambda v: v['path'])
def set_path(base, path, value):
    current = base
    for key in path[:-1]:
        if key not in current:
            current[key] = {}
        require(type(current[key]) is dict, 'object position collision')
        current = current[key]
    current[path[-1]] = copy.deepcopy(value)
def delete_path(base, path):
    parent = lookup(base, path[:-1])
    if type(parent) is dict:
        parent.pop(path[-1], None)
def leaves(obj, path=()):
    if type(obj) is dict and obj:
        return [leaf for key, value in obj.items() for leaf in leaves(value, path + (key,))]
    return [{'path': list(path), 'value': copy.deepcopy(obj)}] if path else []
def objects(obj, path=()):
    if type(obj) is not dict:
        return []
    return ([list(path)] if path else []) + [p for k, v in obj.items() for p in objects(v, path + (k,))]
def subtract(base, keys):
    require(not detail(base, keys), 'old owned values/positions drifted')
    result = copy.deepcopy(base)
    for key in keys:
        p = key['path']; actual = lookup(result, p)
        if event_path(p):
            rest = event_residual(actual, key['value'])
            if rest:
                set_path(result, p, rest)
            else:
                delete_path(result, p)
        else:
            delete_path(result, p)
    return result
def prune(base, created):
    for p in sorted(created, key=len, reverse=True):
        if lookup(base, p) == {}:
            delete_path(base, p)
    return base
def merge(base, template):
    result = copy.deepcopy(base)
    adopt = len(sys.argv) > 7 and sys.argv[7] == 'true'
    for leaf in leaves(template):
        p, new = leaf['path'], leaf['value']; current = lookup(result, p)
        if current is not missing:
            if adopt and same(current, new):
                continue
            require(event_path(p) and tuple(p) in event_ownership and type(current) is list and type(new) is list, 'project key collision')
            canonical = [h for block in new for h in block.get('hooks', [])]
            for block in current:
                require(type(block) is dict and type(block.get('hooks')) is list, 'invalid project hook block')
                for hook in block['hooks']:
                    require(not any(same(hook, h) for h in canonical), 'project hook collides with new owned entry')
            set_path(result, p, new + current)
        else:
            set_path(result, p, new)
    return result
try:
    base = read(filename); keys = parse(encoded_keys)
    require(type(base) is dict, 'settings must be an object'); valid_owned(keys)
    event_ownership = {tuple(k['path']) for k in keys if event_path(k['path'])}
    if op == 'detail':
        result = detail(base, keys)
    elif op in ('merge', 'merge-base', 'reconstruct'):
        template = read(sys.argv[4]); require(type(template) is dict, 'template must be an object')
        created = parse(sys.argv[6]) if len(sys.argv) > 6 else []
        if op == 'reconstruct':
            # Cold health/transaction proof: the template supplies ownership;
            # before-image event members are project-owned residual prefixes.
            event_ownership = {tuple(k['path']) for k in leaves(template) if event_path(k['path'])}
            residual = copy.deepcopy(base)
            for key in leaves(template):
                p = key['path']
                if event_path(p) and restored_event_prefix(lookup(base, p), key):
                    rest = event_residual(lookup(base, p), key['value'])
                    if rest:
                        set_path(residual, p, rest)
                    else:
                        delete_path(residual, p)
        elif op == 'merge-base':
            # User relink has already proved/subtracted the old ownership and
            # supplies its inverse result. Keep all residual event members.
            residual = copy.deepcopy(base)
            recorded_before = copy.deepcopy(base)
            original = read(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else {}
            for key in keys:
                p = key['path']
                if not event_path(p):
                    delete_path(residual, p)
                    if not same(key['value'], lookup(template, p)):
                        delete_path(recorded_before, p)
                else:
                    # Adopt-identical transferred this canonical prefix into
                    # ownership. Relink replaces it even when the new template
                    # keeps/adds only some hooks; project residuals stay unowned.
                    before = lookup(original, p)
                    current = lookup(residual, p)
                    if (before is not missing and current is not missing
                            and restored_event_prefix(before, key)):
                        rest = event_residual(current, key['value'])
                        if rest:
                            set_path(residual, p, rest)
                        else:
                            delete_path(residual, p)
                        if not same(key['value'], lookup(template, p)):
                            # Do not resurrect retired canonical bytes on a
                            # later exact relink/detach from this before-image.
                            if rest:
                                set_path(recorded_before, p, rest)
                            else:
                                delete_path(recorded_before, p)
            residual = prune(residual, created)
        else:
            residual = prune(subtract(base, keys), created)
        before_for_paths = recorded_before if op == 'merge-base' else base
        result = {'after': merge(residual, template), 'owned_keys': leaves(template),
                  'created_paths': sorted({tuple(p) for p in created + objects(template) if lookup(before_for_paths, p) is missing or p in created})}
        if op == 'merge-base':
            result['before'] = recorded_before
    elif op == 'inverse':
        before = read(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else {}
        created = parse(sys.argv[6]) if len(sys.argv) > 6 else []
        result = subtract(base, keys)
        # Live residual event members are authoritative, including edits and
        # removals since the snapshot. A residual-bearing before-image is not a
        # second copy to concatenate or resurrect. The sole restoration case
        # is an exact adopt-identical pre-attach canonical value.
        for key in keys:
            p = key['path']; old = lookup(before, p); current = lookup(result, p)
            if old is not missing:
                if event_path(p):
                    if restored_event_prefix(old, key):
                        require(current is missing or type(current) is list, 'inverse event collision')
                        set_path(result, p, key['value'] + ([] if current is missing else current))
                else:
                    set_path(result, p, old)
        result = prune(result, created)
    else:
        raise ValueError('unknown owned JSON operation')
    print(json.dumps(result, sort_keys=True, indent=2))
except (OSError, ValueError, TypeError, KeyError) as error:
    print('settings ownership: ' + str(error), file=sys.stderr)
    raise SystemExit(3)
PY
}

# reconcile_settings_hooks <canonical_template> <project_settings>
#   canonical_template : path to core-rules/templates/claude-settings.json
#   project_settings   : path to <project>/.claude/settings.json (must exist)
# Prints the merged settings object to stdout. Returns jq's exit status.
reconcile_settings_hooks() {
  local canonical_template project_settings
  canonical_template="$1"
  project_settings="$2"

  # jq slurp idiom mirrors rollout-settings.sh: .[0]=canonical, .[1]=project.
  #   $canonical_cmds — unique basenames of every canonical hook command (args
  #                     stripped first, though canonical commands carry none —
  #                     mirror the project side so the two never silently diverge
  #                     if canonical ever gains a flag).
  #   merged .hooks   — start from canonical .hooks, then for each project event
  #                     key, append the project blocks with their canonical hook
  #                     ENTRIES removed; a block is kept iff a non-canonical entry
  #                     survives. Creating the event array if canonical lacks it.
  # Robustness: (.hooks // {}) / (.hooks // []) so a project (or block) MISSING
  # the key degrades to empty instead of erroring (one malformed block must not
  # abort the whole fleet sync — the caller also captures a hard jq failure).
  # Note: jq `index($b)` returns 0 for a first-position match, and 0 is TRUTHY
  # in jq (only null/false are falsy) — so `index($b) | not` is correct; do not
  # special-case 0.
  jq -s '
    .[0] as $canon
    | .[1] as $proj
    | ([ $canon.hooks[][].hooks[].command | sub(" .*";"") | sub(".*/";"") ] | unique) as $canonical_cmds
    | $proj
    | .hooks = (
        ($canon.hooks // {}) as $base
        | reduce (($proj.hooks // {}) | to_entries[]) as $e (
            $base;
            .[$e.key] = (
              (.[$e.key] // [])
              + ( $e.value
                  | map( .hooks = ((.hooks // []) | map( select( (.command | sub(" .*";"") | sub(".*/";"")) as $b | $canonical_cmds | index($b) | not ) )) )
                  | map( select( (.hooks | length) > 0 ) )
                )
            )
          )
      )
  ' "$canonical_template" "$project_settings"
}
