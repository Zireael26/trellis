#!/usr/bin/env bash
# Decision 1/check 2: compare immutable inventories without Git worktrees.
set -euo pipefail
if [ "$#" -ne 3 ]; then
  printf 'inventory: FAIL usage: scripts/check-gate-inventory.sh <base-sha> <head-sha> <aggregate.tsv>\n' >&2
  exit 64
fi
exec python3 - "$@" <<'PY'
import collections
import csv
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.PIPE)


def snapshot_list(sha, destination):
    # Archive base's own code and inventory; never fire post-checkout hooks
    # through git worktree add in an attached checkout.
    destination.mkdir(parents=True)
    subprocess.run(["tar", "-x", "-C", str(destination)],
                   input=git("archive", sha, "scripts"), check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    environment = os.environ.copy()
    environment.pop("TRELLIS_STAGE_WEIGHTS_TSV", None)
    result = subprocess.run(["bash", str(destination / "scripts/run-tests.sh"),
                             "--scope=local", "--list"], env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise ValueError("--list failed at {}: {}".format(sha, result.stderr.strip()))
    stages = result.stdout.splitlines()
    if not stages or len(stages) != len(set(stages)):
        raise ValueError("empty or duplicate canonical inventory")
    return stages


def names(text):
    declarations = re.findall(r'^\s*@test\s+([\"\'])(.*?)\1\s*\{', text, re.M)
    return collections.Counter(name for _, name in declarations)


def split_blocks(raw):
    # Let bash recognize complete function syntax (including heredocs/quoted
    # braces), rather than guessing that the next column-zero } closes a test.
    lines = raw.splitlines(keepends=True)
    blocks, common = [], []
    index = 0
    while index < len(lines):
        if not re.match(rb'^@test\s+', lines[index]):
            common.append(lines[index]); index += 1; continue
        start = index
        header = re.sub(rb'^@test\s+([\"\']).*?\1\s*\{', b'gate_test() {', lines[index], count=1)
        if header == lines[index]:
            raise ValueError("unsupported Bats declaration")
        index += 1
        while index < len(lines):
            candidate = header + b''.join(lines[start+1:index+1])
            if lines[index].strip() == b'}' and subprocess.run(
                    ["bash", "-n"], input=candidate, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL).returncode == 0:
                blocks.append(b''.join(lines[start:index+1]))
                index += 1
                break
            index += 1
        else:
            raise ValueError("incomplete Bats test block")
    return b''.join(common), blocks


def executable_config(raw):
    # Comment refreshes are mandated by the runner brief; only the timeout
    # DEFAULT may change executable configuration, never the test/lint command.
    return '\n'.join(line for line in raw.decode().splitlines()
                     if line.strip() and not line.lstrip().startswith('#'))


PAYLOAD_SCAN_TEST = "scripts/tests/release-payload-commit.bats"
PAYLOAD_SCAN_PAIR = "scripts/check-gate-inventory.sh|scripts/tests/"


def payload_scan_pair_only(base, head, name):
    """The release-payload scan may change only by adding this tool's one-prefix exemption."""
    if name != PAYLOAD_SCAN_TEST:
        return False
    diff = git("diff", "-U0", "--no-renames", base, head, "--", name).decode().splitlines()
    changed = [line for line in diff
               if line[:1] in "+-" and not line.startswith(("+++", "---"))]
    return changed == ["+" + PAYLOAD_SCAN_PAIR]


def check_range(base, head):
    changed = git("diff", "--name-only", "--no-renames", base, head).decode().splitlines()
    split_paths = {"scripts/tests/doctor-fix.bats", "scripts/tests/doctor-fix-common.bash"} | {
        "scripts/tests/doctor-fix-part{}.bats".format(i) for i in range(1, 5)}
    for name in changed:
        if name.startswith("core-rules/skills/process-gate/"):
            raise ValueError("protected process-gate path changed: " + name)
        test_path = (name.startswith(("scripts/tests/", "tests/", "test/"))
                     or '/tests/' in name or '/test/' in name
                     or Path(name).name.startswith(('test_', 'test-'))
                     or re.search(r'(?:_test\.[^/]+|\.(?:test|spec)\.[^/]+|\.bats)$', name) is not None)
        if test_path and name not in split_paths and not re.fullmatch(r'scripts/tests/run-tests-local[^/]*\.bats', name) and name != "scripts/tests/stage-weights.tsv" and not payload_scan_pair_only(base, head, name):
            raise ValueError("test file outside the split changed: " + name)
    config = ".claude/skills/process-gate-local/local.config.sh"
    if config in changed:
        before = executable_config(git("show", base + ":" + config))
        after = executable_config(git("show", head + ":" + config))
        expected = before.replace('PROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-3660}"',
                                  'PROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-7260}"')
        if after != expected:
            raise ValueError("local.config.sh changed beyond the timeout default")


try:
    base, head, aggregate = sys.argv[1:]
    base = git("rev-parse", "--verify", base + "^{commit}").decode().strip()
    head = git("rev-parse", "--verify", head + "^{commit}").decode().strip()
    check_range(base, head)
    with tempfile.TemporaryDirectory(prefix="gate-inventory-") as temporary:
        base_stages = snapshot_list(base, Path(temporary) / "base")
        head_stages = snapshot_list(head, Path(temporary) / "head")
    with open(aggregate, encoding="utf-8", newline="") as stream:
        reader = csv.reader(stream, delimiter="\t")
        if next(reader, None) != ["ordinal", "stage", "elapsed_seconds", "exit"]:
            raise ValueError("invalid aggregate header")
        rows = list(reader)
    actual = []
    for row in rows:
        if len(row) != 4 or int(row[3]) != 0:
            raise ValueError("invalid row or nonzero stage exit")
        actual.append((int(row[0]), row[1]))
    if collections.Counter(actual) != collections.Counter(enumerate(head_stages, 1)):
        raise ValueError("aggregate missing, duplicate, or changed ordinal/stage")
    old = "bats scripts/tests/doctor-fix.bats"
    parts = ["bats scripts/tests/doctor-fix-part{}.bats".format(i) for i in range(1, 5)]
    if base_stages.count(old) != 1:
        raise ValueError("base doctor-fix stage missing")
    expected = []
    for stage in base_stages:
        expected.extend(parts if stage == old else [stage])
    if head_stages != expected:
        raise ValueError("head inventory changed beyond the four-part doctor split")
    original = names(git("show", base + ":scripts/tests/doctor-fix.bats").decode())
    split = collections.Counter()
    for i in range(1, 5):
        split.update(names(git("show", head + ":scripts/tests/doctor-fix-part{}.bats".format(i)).decode()))
    if not original or split != original:
        raise ValueError("doctor-fix @test name multiset changed")
    source = git("show", base + ":scripts/tests/doctor-fix.bats")
    if re.search(rb'^\s*(?:function\s+)?(?:setup_file|teardown_file)\s*(?:\(\s*\))?\s*\{', source, re.M):
        raise ValueError("doctor-fix uses setup_file/teardown_file")
    common, original_blocks = split_blocks(source)
    if git("show", head + ":scripts/tests/doctor-fix-common.bash") != common:
        raise ValueError("doctor-fix-common.bash differs from original non-test content")
    split_tests = []
    for i in range(1, 5):
        part = git("show", head + ":scripts/tests/doctor-fix-part{}.bats".format(i))
        scaffolding, blocks = split_blocks(part)
        loaders = []
        for line in scaffolding.decode().splitlines():
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            if not re.fullmatch(r'load\s+(?:doctor-fix-common|[\"\'](?:\$BATS_TEST_DIRNAME/)?doctor-fix-common(?:\.bash)?[\"\'])', line.strip()):
                raise ValueError("unexpected doctor-fix part non-test content")
            loaders.append(line)
        if len(loaders) != 1:
            raise ValueError("doctor-fix part must load common exactly once")
        split_tests.extend(blocks)
    if b''.join(split_tests) != b''.join(original_blocks):
        raise ValueError("doctor-fix @test blocks changed byte-for-byte")
    print("inventory: PASS aggregate/head/base, pure doctor split, and protected range")
except (OSError, ValueError, subprocess.CalledProcessError) as exc:
    print("inventory: FAIL {}".format(exc))
    sys.exit(1)
PY
