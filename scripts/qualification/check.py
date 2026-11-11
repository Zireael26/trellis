#!/usr/bin/env python3
"""Read-only qualification verification. An explicit reviewed requirements file is mandatory."""
import argparse
import copy
import json
import math
import os
import re
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
_import_cache = tempfile.TemporaryDirectory(prefix="qualification-check-import-")
sys.pycache_prefix = _import_cache.name
sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import BASELINE, BUILD_INPUTS, EXCLUSIONS, RECORDER_INPUTS, commit, committed_inputs, digest, file_input, git, safe_relative, tree, under, value_digest
from schema import EvidenceError, canonical, loads, validate_named

POLICY_PATH = "specs/074-fast-hooks/evidence/qualification-requirements.json"
# T36/T38 (T73b): the closed block that evidences a cell deferred as not
# qualifiable on available hardware, or (T42-T44) a release bench deferred to
# post-release measurement.
DEFERRAL_SCHEMA = "trellis-qualification-deferral/1"
DEFERRAL_KEYS = {"schema", "task", "deferred", "decision", "reason", "existing_proof"}
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_LOG_BYTES = 128 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def bounded_read(path, limit=MAX_JSON_BYTES):
    require(path.is_file(), "input is not a regular file: " + str(path))
    with path.open("rb") as stream:
        raw = stream.read(limit + 1)
    require(len(raw) <= limit, "file exceeds byte limit: " + str(path))
    return raw


def indexed(rows, key):
    result = {}
    for row in rows:
        require(row[key] not in result, "duplicate " + key + ": " + str(row[key]))
        result[row[key]] = row
    return result


def blob(repo, revision, name):
    safe_relative(name)
    return git(repo, "show", revision + ":" + name)


def ancestor(repo, older, newer):
    return git(repo, "merge-base", older, newer).decode().strip() == older


def platform_key(value):
    return {key: item for key, item in value.items() if key != "ctime_probe"}


def platform_proof(value):
    probe = value["ctime_probe"]
    require(value["ctime_capability"] == probe["capability"], "ctime proof/label mismatch")
    require(probe["capability"] in ("fine", "coarse"), "unknown ctime capability cannot qualify")
    samples = probe["samples_ns"]
    require(probe["same_device"] and len(samples) == 3, "qualification requires a complete same-device ctime probe")
    # Re-derive the recorder's operational classification from retained evidence;
    # probing the checker's filesystem would say nothing about the measured host.
    fine = len(set(samples)) == 3 and all(sample % 1000000000 for sample in samples)
    require(probe["capability"] == ("fine" if fine else "coarse"), "ctime capability contradicts retained samples")


def match_platform(value, policy):
    platform_proof(value)
    require(value["os"] in policy["os"] and value["arch"] in policy["arch"], "platform does not match requirement")
    require(not policy["filesystems"] or value["filesystem"] in policy["filesystems"], "filesystem does not match requirement")
    require(value["ctime_capability"] in policy["ctime"], "ctime does not match requirement")


def target_for(platform):
    os_name, arch = platform["os"], platform["arch"]
    return arch + ("-apple-darwin" if os_name == "Darwin" else "-unknown-linux-musl")


def argv_matches(actual, template, revision, variant, cwd):
    """Match fixed argv exactly; portable recorder paths are one consistent prefix.

    Relative {recorder} paths differ between acquisition machines. They may only
    replace that directory token, never a program/suffix, option or another arg.
    The runtime token is determined by the recorded runtime-relative cwd.
    """
    if len(actual) != len(template):
        return False
    recorder_prefix = None
    for observed, expected in zip(actual, template):
        expected = expected.replace("{runtime}", str(Path(*([".."] * len(Path(cwd).parts))) if cwd != "." else Path(".")))
        expected = expected.replace("{candidate_sha}", revision).replace("{variant}", variant)
        if "{recorder}" in expected:
            pieces = expected.split("{recorder}")
            if len(pieces) != 2 or not observed.startswith(pieces[0]) or (pieces[1] and not observed.endswith(pieces[1])):
                return False
            end = len(observed) - len(pieces[1]) if pieces[1] else len(observed)
            prefix = observed[len(pieces[0]):end]
            if not prefix or "\x00" in prefix or (recorder_prefix is not None and prefix != recorder_prefix):
                return False
            recorder_prefix = prefix
        elif observed != expected:
            return False
    return True


def suite_names(source, requirement):
    """Read the selected suite at the acquired commit; never execute test code.

    Dynamic JS test generators need an explicit reviewed names catalog bound to
    the suite's byte hash in requirements. Literal Bats names are derived here.
    """
    text = source.decode("utf-8")
    if requirement["suite"].endswith(".bats"):
        names = re.findall(r'^\s*@test\s+(["\'])(.*?)\1\s*\{', text, re.M)
        names = [name for _, name in names]
    else:
        require(requirement.get("tests_source_sha256") == digest(source), "dynamic suite requires a source-bound test catalog")
        names = requirement.get("tests", [])
    if requirement["filter"]:
        names = [name for name in names if re.search(requirement["filter"], name)]
    require(names and (not requirement["suite"].endswith(".bats") or len(names) == len(set(names))), "suite/filter selects no tests or ambiguous Bats names")
    return names


def verify_tap(text, expected, nested=None):
    catalogs = {(): expected}
    for key, names in (nested or {}).items():
        path = loads(key)
        require(type(path) is list and path and all(type(name) is str and name for name in path)
                and canonical(path) == key, "invalid nested TAP catalog path")
        catalogs[tuple(path)] = names
    contexts, found = {}, {}
    for line in text.splitlines():
        if not line or line.startswith("TAP version "):
            continue
        # Failure/skip at ANY level fails, even behind a passing container.
        summary = re.fullmatch(r"# (?:fail|cancelled|skipped|todo) (\d+)", line)
        directive = re.match(r"\s*(?:ok|not ok)\b.*#\s*(?:skip|todo)\b", line, re.I)
        if re.match(r"\s*(?:not ok\b|Bail out!)", line) or directive or (summary and int(summary[1]) != 0):
            raise EvidenceError("failed, skipped or incomplete TAP oracle")
        label = re.fullmatch(r"( *)# Subtest: (.+)", line)
        if label:
            require(len(label[1]) % 4 == 0, "ambiguous nested TAP indentation")
            depth = len(label[1]) // 4
            contexts = {level: value for level, value in contexts.items() if level < depth}
            contexts[depth] = label[2]
            continue
        if line.lstrip().startswith("#"):
            continue
        result = re.fullmatch(r"( *)ok\s+(\d+)\s+(?:-\s+)?(.+)", line)
        plan = re.fullmatch(r"( *)1\.\.(\d+)", line)
        if result or plan:
            indent = len((result or plan)[1])
            require(indent % 4 == 0, "ambiguous nested TAP indentation")
            depth = indent // 4
            require(all(level in contexts for level in range(depth)), "nested TAP lacks parent identity")
            path = tuple(contexts[level] for level in range(depth))
            require(path in catalogs, "uncatalogued nested TAP tests")
            group = found.setdefault(path, dict(names=[], ordinals=[], plans=[]))
            if result:
                group["names"].append(result[3])
                group["ordinals"].append(int(result[2]))
            else:
                group["plans"].append(int(plan[2]))
            continue
        # Unsupported indentation must not hide result/plan lines as YAML.
        require(not re.match(r"\s*(?:ok\s+\d+\b|1\.\.\d+\b)", line), "unrecognized TAP result/plan indentation")
        # TAP diagnostics use indented YAML. No result/plan above is ignored.
        require(line[0].isspace(), "unrecognized top-level TAP output")
    require(set(found) == set(catalogs), "missing selected TAP group")
    for path, names in catalogs.items():
        group = found[path]
        require(group["plans"] == [len(names)] and group["ordinals"] == list(range(1, len(names) + 1)), "TAP plan/count mismatch")
        require(group["names"] == names, "TAP names differ from bound suite/filter")


def percentile(values, fraction):
    ordered = sorted(values)
    rank = (len(ordered) - 1) * fraction
    low, high = math.floor(rank), math.ceil(rank)
    return round(ordered[low] + (ordered[high] - ordered[low]) * (rank - low), 1)


def identity(row):
    return row.get("id", row.get("case_id")), row.get("fixture_id"), row.get("boundary_id"), row.get("variant", "warm")


def case_identity(case):
    return case["case_id"], case["fixture_id"], case["boundary_id"], case["variant"]


def observations(row, case, cores):
    require(row["status"] == "ok", "non-ok observations never aggregate")
    require(row.get("load", "normal") == "normal", "contended observation row cannot qualify")
    for flag in case["eligibility"]:
        require(row.get(flag) is True, "ineligible timing boundary: " + flag)
    require(row.get("runs", 0) >= 30 and row.get("warmup") == 2, "invalid requested observation cardinality")
    for field in ("load_start", "load_end"):
        values = row.get(field)
        require(type(values) is list and len(values) == 3 and all(type(x) in (int, float) and math.isfinite(x) and x >= 0 for x in values)
                and values[0] < cores, "contended or missing observation load")
    samples = row["observations"]
    require(type(samples) is list and all(type(item) is dict for item in samples), "malformed observations")
    warm = [item for item in samples if item.get("warmup") is True]
    measured = [item for item in samples if item.get("warmup") is False]
    require(len(warm) == 2 and len(measured) >= 30 and samples[:2] == warm and len(samples) == len(warm) + len(measured),
            "observations require two discarded warmups and at least30 measured rows")
    exits = case.get("expected_exit_codes", [0])
    for item in samples:
        require(type(item.get("timeout")) is bool, "missing timeout observation")
        require((item.get("case_id"), item.get("fixture_id"), item.get("boundary_id")) == case_identity(case)[:3], "observation identity mismatch")
        require(type(item.get("exit")) is int and item["exit"] in exits, "unexpected observation exit")
        members = item.get("member_exits")
        require(type(members) is list and members and all(type(code) is int and code in exits for code in members), "missing or failed member exits")
        require(item["exit"] == next((code for code in members if code != 0), 0), "group/member exit mismatch")
        require(item.get("readiness") is True and not item.get("timeout") and not item.get("callback_timeout")
                and not item.get("exec_error") and not item.get("error") and not item.get("teardown_error"), "unready or timed-out observation")
        require(item.get("aggregation_eligible") is (not item["warmup"]), "warmup/non-ok aggregation forbidden")
        value = item.get("wall_ms")
        require(type(value) in (float, int) and math.isfinite(value) and value >= 0, "invalid observation wall")
    require(len(measured) == row["runs"], "retained observation count differs from requested count")
    values = [item["wall_ms"] for item in measured]
    return dict(n=len(values), p50=percentile(values, .5), p90=percentile(values, .9))


class Checker:
    def __init__(self, repo, head, requirements, runs):
        self.repo, self.head, self.policy, self.runs = repo, commit(repo, head), requirements, runs
        validate_named("requirements", requirements)
        reviewed = loads(blob(repo, self.head, POLICY_PATH).decode())
        require(canonical(requirements) == canonical(reviewed), "requirements differ from committed policy")
        self.commands = indexed(requirements["commands"], "id")
        self.cells = indexed(requirements["cells"], "id")
        self.benches = indexed(requirements["benches"], "id")
        self.cases = indexed(requirements["cases"], "key")
        require(not (set(self.cells) & set(self.benches)), "cell/bench identity collision")
        wanted = set(requirements["coverage"]["criteria"])
        for case in self.cases.values():
            require(case["key"] == canonical(case_identity(case)) and case["criterion"] in wanted, "invalid case identity/criterion mapping")
        for definition in self.cells.values():
            require(set(definition["criteria"]) <= wanted, "cell references unknown criterion")
        require(set(requirements["input_sets"]["exclusions"]) == set(EXCLUSIONS), "unexpected runtime exclusion")
        require(set(requirements["input_sets"]["native_build"]) == set(BUILD_INPUTS), "unexpected build input set")
        for path in requirements["matrix"]["inputs"]:
            require(digest(blob(repo, self.head, path["path"])) == path["sha256"], "stale required-case matrix input: " + path["path"])
        mapped = [row["case_id"] for row in self.cases.values() if row["origin"] == "I-A4"]
        require(set(mapped) == set(requirements["matrix"]["ids"]) and len(mapped) == len(set(mapped)), "incomplete I-A4 denominator")
        for variant in requirements["coverage"]["required_variants"]:
            require(any(row["variant"] == variant and row["origin"] == "regression" for row in self.cases.values()), "missing regression variant: " + variant)
        self.manifest_path = requirements["manifest_path"]
        self.manifest_bytes = blob(repo, self.head, self.manifest_path)
        require(file_input(repo, self.manifest_path)["sha256"] == digest(self.manifest_bytes), "final working manifest differs from T45 head")
        self.manifest = loads(self.manifest_bytes.decode())
        self.generation = digest(self.manifest_bytes)
        self.source = commit(repo, self.manifest["source_commit"])
        require(self.manifest["source_commit"] == self.source, "nonliteral T71 source commit")
        require(set(self.manifest) == {"schema_version", "version", "generation", "source_commit", "inputs", "toolchain", "adapter", "install_path", "assets"}, "invalid final manifest schema")
        require(type(self.manifest["schema_version"]) is int and self.manifest["schema_version"] == 1, "invalid final manifest version")
        require(self.manifest["generation"] == value_digest({key: self.manifest[key] for key in ("version", "inputs", "toolchain")}), "invalid final manifest generation")
        self.final_assets = {}
        for target, entry in self.manifest["assets"].items():
            require(set(entry) == {"path", "sha256", "size", "format", "signature", "minimum_os"}, "invalid final asset entry")
            path = str(Path(self.manifest_path).parent / safe_relative(entry["path"]))
            # Both final Git bytes and shipped working-tree bytes must agree.
            require(digest(blob(repo, self.head, path)) == entry["sha256"], "final asset differs from Git")
            actual = file_input(repo, path)
            require(actual["mode"] == "100755" and actual["sha256"] == entry["sha256"] and (repo / path).stat().st_size == entry["size"], "shipped asset digest/size/mode mismatch")
            self.final_assets[target] = dict(target=target, path=entry["path"], size=entry["size"], sha256=entry["sha256"])
        require(self.final_assets, "no selectable final assets")
        native = Path(self.manifest_path).parent
        adapter = self.manifest["adapter"]
        require(set(adapter) == {"path", "size", "sha256"} and adapter["path"] == "hook-adapter.sh", "invalid final adapter entry")
        adapter_path = str(native / adapter["path"])
        adapter_bytes = blob(repo, self.head, adapter_path)
        actual_adapter = file_input(repo, adapter_path)
        require(digest(adapter_bytes) == adapter["sha256"] == actual_adapter["sha256"] and len(adapter_bytes) == adapter["size"]
                and actual_adapter["mode"] in ("100644", "100755"), "final adapter bytes differ from manifest")
        files = {self.manifest_path, adapter_path, *[str(native / asset["path"]) for asset in self.final_assets.values()]}
        entries = tree(repo, self.head)
        require({path for path in entries if path.startswith(str(native) + "/")} == files, "unlisted/missing final native files")
        expected_paths = {Path(path).relative_to(native) for path in files}
        expected_paths |= {parent for path in list(expected_paths) for parent in path.parents if str(parent) != "."}
        actual_paths = list((repo / native).rglob("*"))
        require(not any(path.is_symlink() for path in actual_paths)
                and {path.relative_to(repo / native) for path in actual_paths} == expected_paths, "unlisted/missing shipped native files or symlink")
        self.cutover = requirements["cutover_commit"]
        require(self.cutover is not None, "T34 cutover_commit is unset; no receipt can qualify")
        require(commit(repo, self.cutover) == self.cutover and ancestor(repo, self.cutover, self.head), "T34 cutover is not integrated")
        require(self.source != self.cutover and ancestor(repo, self.source, self.cutover), "T71 source does not precede T34")
        self.input_cache = {}
        self.harness_cache = {}
        self.verified_runs = {}
        self.selection = None
        self.selection_asset = None
        self.deferred_benches = {}

    def inputs(self, revision, requirement, scope="runtime"):
        key = revision, requirement["id"], scope
        if key not in self.input_cache:
            self.input_cache[key] = committed_inputs(self.repo, revision, self.policy, requirement, scope)
        return self.input_cache[key]

    def selection_change(self, change):
        if self.selection is not None:
            require(change == self.selection, "inconsistent T72 recorded change")
            return
        require(change["removed_target"] == self.policy["selection_only_target"], "T72 removes wrong target")
        revision = commit(self.repo, change["commit"])
        require(revision == change["commit"] and ancestor(self.repo, revision, self.head), "T72 commit not integrated")
        parents = git(self.repo, "rev-list", "--parents", "-n", "1", revision).decode().split()
        require(len(parents) == 2, "T72 change must be a single-parent selection commit")
        previous = parents[1]
        require(change["old_manifest_commit"] == previous, "T72 old generation does not name its parent")
        old_raw, new_raw = blob(self.repo, previous, self.manifest_path), blob(self.repo, revision, self.manifest_path)
        require(digest(old_raw) == change["from_generation"] and digest(new_raw) == change["to_generation"] == self.generation, "T72 generation mismatch")
        old, new = loads(old_raw.decode()), loads(new_raw.decode())
        expected = copy.deepcopy(old)
        require(change["removed_target"] in expected["assets"], "T72 did not remove a selectable asset")
        del expected["assets"][change["removed_target"]]
        require(new == expected, "T72 changed more than target selection")
        removed_entry = old["assets"][change["removed_target"]]
        removed_path = str(Path(self.manifest_path).parent / safe_relative(removed_entry["path"]))
        require(tree(self.repo, previous).get(removed_path, ())[:2] == ("100755", "blob"), "T72 removed asset is not a regular executable")
        removed_bytes = blob(self.repo, previous, removed_path)
        require(digest(removed_bytes) == removed_entry["sha256"] and len(removed_bytes) == removed_entry["size"], "T72 old removed asset does not match its manifest")
        require(removed_path not in tree(self.repo, revision) and removed_path not in tree(self.repo, self.head), "T72 removed asset was replaced or retained")
        changed = set(git(self.repo, "diff-tree", "--no-commit-id", "--name-only", "-r", previous, revision).decode().splitlines())
        # Pin/render exceptions must be explicitly byte-bound in the reviewed
        # policy; absent metadata never grants a path-wide exemption.
        allowed = self.policy["input_sets"].get("selection_only_inputs", {})
        require(changed == {self.manifest_path, removed_path, *allowed}, "T72 edits another path or omits a recorded path")
        old_entries, new_entries = tree(self.repo, previous), tree(self.repo, revision)
        for path, binding in allowed.items():
            require(path in old_entries and path in new_entries and old_entries[path][0] == binding["before_mode"]
                    and new_entries[path][0] == binding["after_mode"], "T72 recorded pin/fixture modes differ")
            require(binding["target"] == change["removed_target"] and binding["role"] in ("pin", "rendered-fixture"), "invalid T72 exception role")
            require(digest(blob(self.repo, previous, path)) == binding["before_sha256"] and digest(blob(self.repo, revision, path)) == binding["after_sha256"], "T72 recorded pin/fixture bytes differ")
        self.selection = change
        self.selection_asset = removed_path

    def fresh(self, run, requirement, build=False, before=False):
        revision = run["candidate_sha"]
        require(commit(self.repo, revision) == revision, "unknown runtime candidate")
        scope = "native-build" if build else "runtime"
        require(run["runtime"]["scope"] == scope and run["runtime"]["clean"] and run["runtime"]["stable"]
                and run["runtime"]["generation"] is None and run["acquisition_error"] is None, "unqualified runtime input generation")
        expected = self.inputs(revision, requirement, scope)
        expected_digest = value_digest(expected)
        require(run["runtime"]["inputs"] == expected and run["runtime_input_digest"] == expected_digest
                and run["runtime"]["committed_input_digest"] == expected_digest and run["runtime"]["end_input_digest"] == expected_digest,
                "runtime input identity/digest does not name acquired commit")
        if before:
            require(revision == BASELINE == self.policy["baseline_sha"] and run["phase"] == "before", "before runtime is not pinned3661cb5f2")
            return
        require(ancestor(self.repo, revision, self.head), "candidate is not an ancestor of T45")
        if build:
            require(revision == self.source and run["phase"] == "build", "build candidate is not T71 source")
        else:
            require(ancestor(self.repo, self.cutover, revision), "runtime candidate predates T34 cutover")
        final = self.inputs(self.head, requirement, scope)
        if expected != final:
            allowed = {self.manifest_path, self.selection_asset, *self.policy["input_sets"].get("selection_only_inputs", {})} if self.selection and not build else set()
            left = {item["path"]: item for item in expected}
            right = {item["path"]: item for item in final}
            changed = {path for path in left.keys() | right.keys() if left.get(path) != right.get(path)}
            require(allowed and changed <= allowed and ancestor(self.repo, revision, self.selection["commit"]), "stale executed inputs: " + ",".join(sorted(changed)))
            bound_before = {item["path"]: item for item in self.inputs(self.selection["old_manifest_commit"], requirement, scope)}
            bound_after = {item["path"]: item for item in self.inputs(self.selection["commit"], requirement, scope)}
            require(all(left.get(path) == bound_before.get(path) and right.get(path) == bound_after.get(path) for path in allowed),
                    "selection-only executed input differs from bound endpoints")

    def harness_at(self, revision):
        if revision not in self.harness_cache:
            selected = {name: entry for name, entry in sorted(tree(self.repo, revision).items())
                        if any(under(name, prefix) for prefix in RECORDER_INPUTS)}
            raw = git(self.repo, "cat-file", "--batch", data=b"".join(entry[2].encode() + b"\n" for entry in selected.values()))
            result, position = [], 0
            for name, (mode, kind, oid) in selected.items():
                require(kind == "blob", "unsupported harness submodule")
                end = raw.index(b"\n", position)
                header = raw[position:end].decode().split()
                require(len(header) == 3 and header[:2] == [oid, "blob"], "invalid harness Git object")
                size = int(header[2])
                content = raw[end + 1:end + 1 + size]
                require(len(content) == size and raw[end + 1 + size:end + 2 + size] == b"\n", "truncated harness Git object")
                result.append(dict(path=name, mode=mode, sha256=digest(content)))
                position = end + size + 2
            self.harness_cache[revision] = result
        return self.harness_cache[revision]

    def harness_at_head(self):
        return [item for item in self.harness_at(self.head) if not item["path"].startswith("scripts/qualification/")]

    @staticmethod
    def recorder_implementation(inputs):
        # Checker-only changes and documentation do not invalidate acquisition.
        # All other recorder-side code/data (not just today's Python filenames)
        # is pinned to reviewed HEAD; no implicit old-recorder allowlist exists.
        return [item for item in inputs if item["path"].startswith("scripts/qualification/")
                and item["path"] != "scripts/qualification/check.py" and not item["path"].endswith(".md")]

    def verify_recorder(self, record):
        try:
            revision = commit(self.repo, record["recorder_sha"])
        except EvidenceError as error:
            raise EvidenceError("unknown recorder commit") from error
        require(revision == record["recorder_sha"] and ancestor(self.repo, revision, self.head), "recorder commit is not an ancestor of checked head")
        require(record["harness_inputs"] == self.harness_at(revision), "harness hashes differ from recorder commit")
        reviewed = self.recorder_implementation(self.harness_at(self.head))
        required = {"scripts/qualification/" + name for name in ("record.py", "model.py", "schema.py", "bench-log.py",
                    "run-record.schema.json", "receipt.schema.json", "requirements.schema.json")}
        require(required <= {item["path"] for item in reviewed}, "checked head has no complete reviewed recorder")
        require(self.recorder_implementation(record["harness_inputs"]) == reviewed, "recorder implementation differs from checked head")

    def acquisition_policy(self, record, location, requirement):
        name = "policy-" + record["requirements_sha256"] + ".json"
        require(record["requirements_snapshot"] == name, "acquisition policy snapshot name mismatch")
        path = location.parent / name
        require(path.is_file() and not path.is_symlink(), "missing acquisition policy snapshot")
        raw = bounded_read(path)
        require(digest(raw) == record["requirements_sha256"], "acquisition policy hash mismatch")
        policy = loads(raw.decode())
        validate_named("requirements", policy)
        selected = [command for command in policy["commands"] if command["id"] == requirement["id"]]
        require(len(selected) == 1, "acquired policy requirement is missing or duplicate")
        fields = ("id", "kind", "argv", "cwd", "suite", "filter", "format", "expected_exit", "inputs", "condition", "target")
        require(all(selected[0][key] == requirement[key] for key in fields), "acquired command binding differs from final requirements")
        for key in ("exclusions", "native_build", "rendered_registrations"):
            require(policy["input_sets"][key] == self.policy["input_sets"][key], "acquired input-set binding differs from final requirements")

    def run(self, run_id, requirement, receipt=None, build=False, before=False):
        require(run_id in self.runs, "missing run record: " + run_id)
        record, location = self.runs[run_id]
        if receipt is not None:
            require(record["candidate_sha"] == receipt["candidate_sha"], "receipt/runtime candidate disagreement")
        cache_key = run_id, requirement["id"], build, before
        if cache_key not in self.verified_runs:
            validate_named("run-record", record)
            self.acquisition_policy(record, location, requirement)
            self.verify_recorder(record)
            harness = record["harness_inputs"]
            indexed(harness, "path")
            for item in harness:
                safe_relative(item["path"])
            require(harness == sorted(harness, key=lambda item: item["path"]) and value_digest(harness) == record["recorder_input_digest"], "recorder/harness input digest mismatch")
            if requirement["kind"] == "bench":
                acquired = [item for item in harness if not item["path"].startswith("scripts/qualification/")]
                require(acquired == self.harness_at_head(), "stale or unbound executed recorder-side bench/helper inputs")
                mapping = {item["path"]: item for item in harness}
                for entry in self.policy["matrix"]["inputs"]:
                    require(entry["path"] in mapping and mapping[entry["path"]]["sha256"] == entry["sha256"], "executed harness differs from required-case matrix pin")
            measurement = record["measurement"]
            require(measurement["same_device"] and measurement["runtime_device"] == measurement["scratch_device"], "measured TMPDIR/runtime filesystem mismatch")
            require(record["requirement_id"] == requirement["id"], "run requirement ID mismatch")
            require(argv_matches(record["argv"], requirement["argv"], record["candidate_sha"], record["variant"], record["cwd"])
                    and record["cwd"] == requirement["cwd"] and record["cwd_base"] == "runtime", "run argv/cwd differs from requirement")
            require(record["exit"] == requirement["expected_exit"] and not record["exec_error"] and not record["timeout"], "required command exit/timeout failure")
            platform_proof(record["platform"])
            facts = record["load_facts"]
            require(len(facts["start"]) == len(facts["end"]) == 3, "incomplete load facts")
            contended = (facts["battery_running"] or facts["start"][0] >= facts["logical_cores"] or facts["end"][0] >= facts["logical_cores"])
            require(record["load"] == ("contended" if contended else "normal"), "load label contradicts acquired facts")
            if requirement["kind"] == "bench":
                require(not contended, "contended timing run cannot qualify")
            logs = {}
            for name, entry in record["logs"].items():
                require(Path(entry["path"]).name == entry["path"], "unsafe retained log path")
                path = location.parent / entry["path"]
                require(not path.is_symlink() and path.is_file(), "missing retained log")
                raw = bounded_read(path, MAX_LOG_BYTES)
                require(digest(raw) == entry["sha256"], "retained log hash mismatch")
                logs[name] = raw.decode("utf-8")
            self.fresh(record, requirement, build, before)
            if requirement["format"] == "tap":
                source = blob(self.repo, record["candidate_sha"], requirement["suite"])
                verify_tap(logs["stdout"], suite_names(source, requirement), requirement.get("nested_tests"))
            elif requirement["format"] == "bench":
                payload = loads(logs["stdout"])
                require(type(payload) is dict and payload.get("status") == "ok" and type(payload.get("results")) is list, "failed bench invocation")
                require(all(type(row) is dict and type(row.get("id")) is str for row in payload["results"]), "malformed bench case rows")
                if requirement.get("bench_schema"):
                    require(payload.get("schema") == requirement["bench_schema"], "bench output schema mismatch")
                    require(payload.get("condition") == payload.get("declared_condition") == "normal", "contended bench envelope cannot qualify")
                    require(payload.get("source", {}).get("commit") == record["candidate_sha"], "bench runtime identity mismatch")
                    require(payload.get("host", {}).get("cpu_count") == record["load_facts"]["logical_cores"], "bench host cardinality mismatch")
                    require(payload["host"].get("gate_or_bats_running") is False, "bench battery liveness is not quiet")
                    for sample in (payload.get("load", {}).get("start"), payload.get("load", {}).get("end")):
                        require(type(sample) is list and len(sample) == 3 and all(type(x) in (int, float) and math.isfinite(x) and x >= 0 for x in sample)
                                and sample[0] < record["load_facts"]["logical_cores"], "contended/missing bench envelope load")
                logs["bench"] = payload
            self.verified_runs[cache_key] = record, logs
        record, logs = self.verified_runs[cache_key]
        if receipt is not None:
            require(record["candidate_sha"] == receipt["candidate_sha"], "receipt/runtime candidate disagreement")
            require(platform_key(record["platform"]) == platform_key(receipt["platform"]), "receipt/run platform disagreement")
            if receipt["route"] == "native":
                require(not record["platform"]["emulated"], "emulated native run")
        return record, logs

    def bench_owner(self, command_id):
        owners = [key for key, bench in self.benches.items() if command_id in bench["requirements"]]
        return owners[0] if len(owners) == 1 else None

    def deferred_bench_commands(self, definition):
        """T42-T44: a cell's bench command whose unique budget owner is a
        deferred bench is not required; the cell keeps its other commands."""
        if not self.deferred_benches:
            return []
        return sorted(name for name in definition["requirements"] if name in self.commands
                      and self.commands[name]["kind"] == "bench" and self.bench_owner(name) in self.deferred_benches)

    def active_commands(self, definition, route):
        result = []
        skipped = set(self.deferred_bench_commands(definition))
        for name in definition["requirements"]:
            require(name in self.commands, "unknown required command: " + name)
            command = self.commands[name]
            if name in skipped:
                continue
            condition = command["condition"]
            selected = set(self.final_assets)
            if definition["route"] == "build" and self.selection:
                selected.add(self.selection["removed_target"])
            if condition == "selected-target" and command["target"] not in selected:
                continue
            if condition == "native-route" and route != "native" or condition == "legacy-route" and route != "legacy":
                continue
            result.append(command)
        require(result, "no applicable commands")
        return result

    def runtime_identity(self, receipt, definition):
        match_platform(receipt["platform"], definition["platform"])
        target = definition["target"] or target_for(receipt["platform"])
        require(target == target_for(receipt["platform"]), "runtime target does not match platform architecture")
        expected_route = "native" if target in self.final_assets else "legacy"
        require(receipt["route"] == expected_route, "receipt route disagrees with final manifest")
        if definition["route"] in ("native", "legacy"):
            require(receipt["route"] == definition["route"], "route disagrees with required cell")
        require(receipt["t71_source_commit"] == self.source, "receipt T71 source mismatch")
        require(ancestor(self.repo, self.cutover, receipt["candidate_sha"]), "runtime candidate predates T34 cutover")
        require(digest(blob(self.repo, receipt["candidate_sha"], self.manifest_path)) == receipt["manifest_generation"], "receipt manifest generation does not name acquired candidate")
        if receipt["manifest_generation"] != self.generation:
            require(self.selection and receipt["manifest_generation"] == self.selection["from_generation"], "stale manifest generation")
            old = loads(blob(self.repo, self.selection["old_manifest_commit"], self.manifest_path).decode())
            require(old["assets"].get(target) == self.manifest["assets"].get(target), "T72 changed this cell's platform entry")
        expected_asset = self.final_assets[target]["sha256"] if expected_route == "native" else None
        require(receipt["asset_sha256"] == expected_asset, "receipt asset differs from final shipped bytes")
        if expected_route == "native":
            require(not receipt["platform"]["emulated"], "emulated native receipt")

    def native_build(self, revision):
        """T71's native build input map at REVISION, from the build script's own
        definition (model.native_build_inputs), cached per revision."""
        cache = self.__dict__.setdefault("native_build_cache", {})
        if revision not in cache:
            cache[revision] = native_build_inputs(self.repo, revision)
        return cache[revision]

    def build_cell(self, receipt, definition):
        require(receipt["candidate_sha"] == receipt["t71_source_commit"] == self.source, "artifacts candidate is not T71 source")
        require(receipt["manifest_generation"] == self.generation, "artifacts names wrong final generation")
        commands = self.active_commands(definition, "build")
        outcomes, outputs, hosts, signing_tools = {}, {}, [], set()
        for command in commands:
            matches = [rid for rid in receipt["runs"] if self.runs.get(rid, ({}, None))[0].get("requirement_id") == command["id"]]
            require(len(matches) == 1, "missing or duplicate build command")
            record, _ = self.run(matches[0], command, build=True)
            data = record["artifacts"]
            require(data is not None and data["source_commit"] == self.source and data["version"] == self.manifest["version"], "missing or mismatched build acquisition")
            target = command["target"]
            require(target is not None and record["platform"]["os"] == ("Darwin" if target.endswith("apple-darwin") else "Linux"), "build host OS/target mismatch")
            require(data["toolchain"] == receipt["toolchain"] or all(data["toolchain"][k] == receipt["toolchain"][k] for k in ("channel", "rustc", "cargo", "cargo_lock_sha256", "rust_toolchain_sha256")), "build toolchain mismatch")
            if target.endswith("apple-darwin"):
                require(data["toolchain"]["codesign"], "missing Darwin codesign identity")
                signing_tools.add(data["toolchain"]["codesign"])
            declared = indexed(data["entries"], "target")
            actual = indexed(data["outputs"], "target")
            require(set(declared) == set(actual) == set(data["toolchain"]["targets"]), "build target inventory mismatch")
            require(target in actual and target in declared, "built target output absent")
            expected_entry = self.manifest["assets"].get(target)
            if expected_entry is None and self.selection and target == self.selection["removed_target"]:
                previous = loads(blob(self.repo, self.selection["old_manifest_commit"], self.manifest_path).decode())
                expected_entry = previous["assets"][target]
            require(expected_entry is not None and declared[target] == dict(expected_entry, target=target), "build/final asset entry metadata differs")
            require(actual[target] == {key: declared[target][key] for key in ("target", "path", "size", "sha256")}, "build declared/output bytes differ")
            outputs[target] = actual[target]
            hosts.append(dict(host_id=record["host_id"], platform=record["platform"]))
            outcomes[command["id"]] = record["exit"]
            native = self.native_build(self.source)
            require(data["inputs"] == self.manifest["inputs"] == native, "native manifest input set differs from T71")
            require(data["toolchain"]["cargo_lock_sha256"] == native["native/trellis-hooks/Cargo.lock"]
                    and data["toolchain"]["rust_toolchain_sha256"] == native["native/trellis-hooks/rust-toolchain.toml"], "native toolchain input hash mismatch")
        native_build_unchanged(self.native_build(self.source), self.native_build(self.head))
        require(signing_tools == ({receipt["toolchain"]["codesign"]} if receipt["toolchain"]["codesign"] is not None else set()), "receipt codesign identity differs from build hosts")
        require(indexed(receipt["outputs"], "target") == outputs, "receipt outputs differ from original T71 build records")
        require(all(outputs.get(target) == asset for target, asset in self.final_assets.items()), "final manifest entry differs from T71 build output")
        require(set(outputs) - set(self.final_assets) <= ({self.selection["removed_target"]} if self.selection else set()), "unrecorded build target selection difference")
        require(set(receipt["toolchain"]["targets"]) == set(outputs), "receipt build target inventory differs from outputs")
        require(sorted(canonical(host) for host in receipt["build_hosts"]) == sorted(set(canonical(host) for host in hosts)), "build hosts differ from acquired runs")
        for key in ("channel", "rustc", "cargo_lock_sha256", "rust_toolchain_sha256"):
            require(receipt["toolchain"][key] == self.manifest["toolchain"][key], "final toolchain differs from build record")
        return outcomes, {}, "PASS"

    def bench_cases(self, receipt, bench_id, acquired):
        rows = {}
        for record, logs in acquired:
            if "bench" not in logs:
                continue
            require(record["phase"] == "after", "after bench phase mismatch")
            for row in logs["bench"]["results"]:
                key = identity(row)
                require(key not in rows, "duplicate after case")
                rows[key] = row, record
        expected_ids = {case_identity(case) for case in self.cases.values()}
        require(set(rows) <= expected_ids, "unknown measured case")
        claims = indexed(receipt["claims"]["cases"], "key")
        require(set(claims) == set(self.cases), "required case denominator missing/unknown")
        criteria = {}
        for key, original_case in self.cases.items():
            case = dict(original_case)
            case.setdefault("expected_exit_codes", self.policy.get("case_exit_codes", {}).get(case["fixture_id"], [0]))
            claim = claims[key]
            app = case["applicability"][bench_id][receipt["route"]]
            ctime = receipt["platform"]["ctime_capability"]
            applicable = app["applicable"] and ctime in app["ctime"]
            if not applicable:
                reason = app["reason"] if not app["applicable"] else "Requires ctime " + ",".join(app["ctime"]) + "; observed " + ctime + "."
                require(claim == dict(key=key, n_a_reason=reason), "N/A reason differs from requirements")
                continue
            require("n_a_reason" not in claim and case_identity(case) in rows, "required case omitted or offered as diagnostic")
            row, record = rows[case_identity(case)]
            measured = observations(row, case, record["load_facts"]["logical_cores"])
            before_rows = []
            require(claim["before_runs"], "before figure has no retained run")
            supplied_before = {rid for rid, (prior, _) in self.runs.items()
                               if prior["phase"] == "before" and prior["requirement_id"] == record["requirement_id"]
                               and prior["host_id"] == record["host_id"] and platform_key(prior["platform"]) == platform_key(record["platform"])}
            matching_before = set()
            for rid in sorted(supplied_before | set(claim["before_runs"])):
                require(rid in self.runs, "missing before run")
                before_record = self.runs[rid][0]
                require(before_record["requirement_id"] in self.commands, "unknown before requirement")
                command = self.commands[before_record["requirement_id"]]
                require(command["kind"] == "bench" and command["id"] == record["requirement_id"], "before run does not use the same bound bench command")
                prior, logs = self.run(rid, command, before=True)
                require(prior["host_id"] == record["host_id"] and platform_key(prior["platform"]) == platform_key(record["platform"]), "before/after host or platform mismatch")
                matches = [item for item in logs["bench"]["results"] if identity(item) == case_identity(case)]
                require(len(matches) <= 1, "duplicate before case/fixture/boundary/variant")
                if matches:
                    matching_before.add(rid)
                    before_rows += matches
            require(before_rows, "before case/fixture/boundary/variant mismatch")
            require(set(claim["before_runs"]) == matching_before, "before run selection omits supplied matching run")
            before_values = []
            for before_row in before_rows:
                observations(before_row, case, record["load_facts"]["logical_cores"])
                before_values += [item["wall_ms"] for item in before_row["observations"] if not item["warmup"]]
            previous = {p: percentile(before_values, fraction) for p, fraction in (("p50", .5), ("p90", .9))}
            budget = case["budgets"][bench_id]
            passing = True
            if budget["kind"] == "relative":
                passing = all(measured[p] <= previous[p] * budget["factor"] for p in ("p50", "p90"))
            elif budget["kind"] == "absolute":
                passing = all(measured[p] <= budget[p] if budget["inclusive"] else measured[p] < budget[p] for p in ("p50", "p90"))
            verdict = "PASS" if passing else "BLOCKED" if case["criterion"] == "SC13" else "FAIL"
            derived = dict(key=key, **measured, before_p50=previous["p50"], before_p90=previous["p90"], before_runs=claim["before_runs"], verdict=verdict)
            require(claim == derived, "case counts/percentiles/before/verdict claim differs from observations: " + case["case_id"])
            previous_verdict = criteria.get(case["criterion"], "PASS")
            criteria[case["criterion"]] = verdict if previous_verdict == "PASS" else previous_verdict
        return criteria

    def deferrals(self, receipts):
        """T36/T38 (T73b): a cell the requirements defer as not qualifiable on
        available hardware is evidenced by exactly one closed deferral block,
        equal to its requirements entry, and by nothing else. A deferral block
        for any other cell, a missing block, or a receipt (any claim, PASS or
        not) for a deferred cell is refused. Rule 5 is unchanged: a deferred
        cell is not qualified on another platform, it is not qualified.
        T42-T44: a release bench deferred to post-release measurement follows
        the same rules, with "bench" in place of "cell"."""
        policy = {"cell": {}, "bench": {}}
        for row in self.policy.get("deferred_cells", []):
            name = row["cell"]
            require(name not in policy["cell"], "duplicate deferred cell: " + name)
            require(name in self.cells and name != "artifacts", "deferred cell is not a runtime cell: " + name)
            require(row["task"] in self.cells[name]["tasks"], "deferred cell task mismatch: " + name)
            policy["cell"][name] = row
        for row in self.policy.get("deferred_benches", []):
            name = row["bench"]
            require(name not in policy["bench"], "duplicate deferred bench: " + name)
            require(name in self.benches, "deferred bench is not a release bench: " + name)
            require(row["task"] == self.benches[name]["task"], "deferred bench task mismatch: " + name)
            policy["bench"][name] = row
        blocks, ordinary = {"cell": {}, "bench": {}}, []
        for receipt in receipts:
            if type(receipt) is not dict or receipt.get("schema") != DEFERRAL_SCHEMA:
                ordinary.append(receipt)
                continue
            kinds = [kind for kind in ("cell", "bench") if kind in receipt]
            require(len(kinds) == 1 and set(receipt) == DEFERRAL_KEYS | set(kinds), "invalid deferral block")
            kind = kinds[0]
            name = receipt[kind]
            require(type(name) is str and name not in blocks[kind], "duplicate deferral block")
            require(name in policy[kind], "deferral block for a " + kind + " the requirements do not defer: " + str(name))
            row = policy[kind][name]
            require(receipt["deferred"] is True and (receipt["task"], receipt["decision"], receipt["reason"]) == (row["task"], row["decision"], row["reason"]),
                    "deferral block differs from its requirements entry: " + name)
            proof = receipt["existing_proof"]
            require(type(proof) is list and proof and all(type(item) is str and item.strip() for item in proof), "deferral block names no existing proof: " + name)
            blocks[kind][name] = receipt
        for kind in ("cell", "bench"):
            require(set(blocks[kind]) == set(policy[kind]), "deferred " + kind + " has no deferral block: " + ",".join(sorted(set(policy[kind]) - set(blocks[kind]))))
        return policy["cell"], policy["bench"], ordinary

    def evaluate(self, receipts):
        deferred, self.deferred_benches, receipts = self.deferrals(receipts)
        deferred_benches = self.deferred_benches
        receipt_map = {}
        for receipt in receipts:
            validate_named("receipt", receipt)
            name = receipt.get("cell", receipt.get("bench"))
            require(name not in receipt_map, "duplicate receipt: " + name)
            require(name in (self.cells if "cell" in receipt else self.benches), "unknown receipt: " + name)
            require(name not in deferred, "a receipt claims a deferred cell: " + name)
            require(name not in deferred_benches, "a receipt claims a deferred bench: " + name)
            receipt_map[name] = receipt
        require(set(receipt_map) == (set(self.cells) - set(deferred)) | (set(self.benches) - set(deferred_benches)), "missing required receipt")
        cited = {rid for receipt in receipts for rid in receipt["runs"]}
        cited |= {rid for receipt in receipts for case in receipt["claims"]["cases"] for rid in case.get("before_runs", [])}
        require(not (set(self.runs) - cited), "uncited supplied run record: " + ",".join(sorted(set(self.runs) - cited)))
        for receipt in receipts:
            if "selection_change" in receipt:
                self.selection_change(receipt["selection_change"])
        results, criteria, errors = {}, {}, []
        for name, receipt in receipt_map.items():
            definition = self.cells[name] if "cell" in receipt else self.benches[name]
            try:
                require(receipt["task"] in definition.get("tasks", [definition.get("task")]), "receipt task mismatch")
                require(all(rid in self.runs for rid in receipt["runs"]), "receipt run record missing")
                expected_commands = self.active_commands(definition, receipt.get("route", "build"))
                required_names = {command["id"] for command in expected_commands}
                require({self.runs[rid][0]["requirement_id"] for rid in receipt["runs"]} == required_names, "missing/unknown acquired command")
                if name == "artifacts":
                    commands, oracles, verdict = self.build_cell(receipt, definition)
                    case_results = {}
                else:
                    self.runtime_identity(receipt, definition)
                    commands, oracles, acquired = {}, {}, []
                    hosts = set()
                    for command in expected_commands:
                        matches = [rid for rid in receipt["runs"] if self.runs[rid][0]["requirement_id"] == command["id"]]
                        require(matches, "required command has no run")
                        for rid in matches:
                            record, logs = self.run(rid, command, receipt)
                            hosts.add(record["host_id"])
                            acquired.append((record, logs))
                            commands[command["id"]] = record["exit"]
                        if command["kind"] == "oracle":
                            oracles[command["id"]] = "PASS"
                    require(len(hosts) == 1, "receipt combines different hosts")
                    has_bench = any("bench" in logs for _, logs in acquired)
                    bench_id = name
                    if has_bench and "cell" in receipt:
                        bench_commands = {command["id"] for command in expected_commands if command["kind"] == "bench"}
                        owners = [key for key, bench in self.benches.items() if bench_commands <= set(bench["requirements"])]
                        require(len(owners) == 1, "cell bench commands have no unique budget owner")
                        bench_id = owners[0]
                    case_results = self.bench_cases(receipt, bench_id, acquired) if has_bench else {}
                    require(has_bench or receipt["claims"]["cases"] == [], "non-bench receipt has case claims")
                    verdict = "FAIL" if "FAIL" in case_results.values() else "BLOCKED" if "BLOCKED" in case_results.values() else "PASS"
                require(receipt["claims"]["commands"] == commands and receipt["claims"]["oracles"] == oracles, "command/oracle claims disagree with acquired evidence")
                require(receipt["claims"]["verdict"] == verdict, "claimed verdict is not derived verdict")
                results[name] = verdict
                for criterion, result in case_results.items():
                    if criteria.get(criterion, "PASS") == "PASS":
                        criteria[criterion] = result
                for criterion in definition.get("criteria", []):
                    if criterion not in criteria:
                        criteria[criterion] = verdict
            except Exception as error:
                # Input/receipt boundary only. No exception can grant a partial
                # pass; KeyboardInterrupt/SystemExit are deliberately not caught.
                results[name] = "FAIL"
                affected = set(definition.get("criteria", []))
                if "bench" in receipt:
                    affected |= {case["criterion"] for case in self.cases.values()}
                    affected.add("SC10")
                for criterion in affected & set(self.policy["coverage"]["criteria"]):
                    criteria[criterion] = "FAIL"
                errors.append(name + ": " + type(error).__name__ + ": " + str(error))
        wanted = self.policy["coverage"]["criteria"]
        # T42-T44: a criterion with case rows budgeted by a deferred bench has
        # no timing verdict yet. It reports DEFERRED, never PASS; a functional
        # FAIL or error stays visible.
        timing_deferred = {case["criterion"] for case in self.cases.values() if set(case["budgets"]) & set(deferred_benches)}
        for criterion in wanted:
            if criterion in timing_deferred and criteria.get(criterion, "PASS") == "PASS":
                criteria[criterion] = "DEFERRED"
            elif criterion not in criteria:
                criteria[criterion] = "FAIL"
                errors.append("uncovered criterion: " + criterion)
        for name in list(deferred) + list(deferred_benches):
            results[name] = "DEFERRED"
        cells_pass = all(results[name] == "PASS" for name in self.cells if name not in deferred)

        # DEFERRED is set above only for a policy timing-deferred criterion.
        eligible = not errors and cells_pass and all(criteria[key] in ("PASS", "DEFERRED") or criteria[key] == "BLOCKED" and key == "SC13" for key in wanted)
        # A deferred cell or bench may leave the release eligible, never fully passed.
        summary = None
        if eligible and deferred_benches:
            summary = "functional qualification complete; timing criteria " + criteria_span(timing_deferred & set(wanted)) + " deferred: post-release measurement"
        rows = lambda table: {name: dict(task=row["task"], decision=row["decision"], reason=row["reason"]) for name, row in sorted(table.items())}
        skipped = {name: self.deferred_bench_commands(definition) for name, definition in self.cells.items() if name not in deferred}
        return dict(head=self.head, t71_source_commit=self.source, manifest_generation=self.generation,
                    cells={name: results[name] for name in self.cells}, benches={name: results[name] for name in self.benches},
                    deferred=rows(deferred), deferred_benches=rows(deferred_benches),
                    deferred_bench_commands={name: commands for name, commands in skipped.items() if commands},
                    criteria=criteria, release_eligible=eligible,
                    all_criteria_pass=eligible and all(criteria[key] == "PASS" for key in wanted) and not deferred, errors=errors,
                    summary=summary)


def criteria_span(keys):
    """{SC1..SC10, SC13} -> 'SC1-SC10 and SC13'."""
    numbers, spans = sorted(int(key[2:]) for key in keys), []
    for number in numbers:
        if spans and spans[-1][1] == number - 1:
            spans[-1][1] = number
        else:
            spans.append([number, number])
    text = ["SC%d" % low if low == high else "SC%d-SC%d" % (low, high) for low, high in spans]
    return ", ".join(text[:-1]) + " and " + text[-1] if len(text) > 1 else "".join(text)


def read_receipt(path):
    require(path.name != "sc13-early.md", "early feasibility is not qualification evidence")
    text = bounded_read(path).decode("utf-8")
    match = re.match(r"\s*```json\s*\n(.*?)\n```", text, re.S)
    require(match is not None, "receipt must begin with one fenced JSON block")
    return loads(match[1])


NATIVE_BUILD_SCRIPT = "scripts/build-native-hooks.sh"
_NATIVE_DRIVER = r"""
import json, sys
from pathlib import Path
script, root = Path(sys.argv[1]), Path(sys.argv[2])
text = script.read_text(encoding="utf-8")
start = text.index("<<'PY'\n") + len("<<'PY'\n")
program = text[start:text.rindex("\nPY")]
# Definitions only: drop the trailing CLI entry block, never run a subcommand.
definitions = program[:program.rindex("\ntry:\n")]
sys.argv = ["-", str(root)]
namespace = {"__name__": "build_native_hooks_definitions"}
exec(compile(definitions, str(script), "exec"), namespace)
print(json.dumps(namespace["build_inputs"](root), sort_keys=True))
"""


def native_build_inputs(repo, revision):
    """The native build input map {path: sha256} exactly as T71 defines it.

    Never a second copy of the rule: the build script's own definitions at
    REVISION (build_inputs, include discovery, BUILD_SCOPE) run in a private
    shared clone checked out at REVISION, in a separate process. Only the
    trailing CLI block is dropped; no subcommand (build/verify) runs. Lives in
    the checker, so it is not recorder implementation.
    """
    import shutil
    import subprocess
    import tempfile
    work = tempfile.mkdtemp(prefix="trellis-native-inputs.")
    try:
        clone = Path(work) / "checkout"
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_NO_REPLACE_OBJECTS="1")
        for args in (["clone", "-q", "--shared", "--no-checkout", str(repo), str(clone)],
                     ["-C", str(clone), "-c", "advice.detachedHead=false", "checkout", "-q", "--detach", revision]):
            done = subprocess.run(["git", *args], env=env, capture_output=True)
            require(done.returncode == 0, "native build input checkout failed at " + revision)
        out = subprocess.run([sys.executable, "-I", "-c", _NATIVE_DRIVER, str(clone / NATIVE_BUILD_SCRIPT), str(clone)],
                             env=env, capture_output=True)
        require(out.returncode == 0, "native build input definition failed at " + revision + ": " + out.stderr.decode(errors="replace")[-400:])
        return json.loads(out.stdout)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def native_build_unchanged(at_source, at_head):
    """Rule 8a: no native build input, including an include_bytes!/include_str!
    target outside native/ (lib/deps.sh, parity-cases.json, ...), may differ
    between the T71 source and the T45 head."""
    changed = sorted(path for path in at_source.keys() | at_head.keys() if at_source.get(path) != at_head.get(path))
    require(not changed, "native build input changed after T71: " + ",".join(changed))


def directory_records(repo, head, directory):
    directory = directory if directory.is_absolute() else repo / directory
    require(not directory.is_symlink() and directory.is_dir(), "evidence directory is missing or a symlink")
    relative = directory.resolve().relative_to(repo)
    safe_relative(relative.as_posix())
    prefix = relative.as_posix() + "/"
    committed = {name: entry for name, entry in tree(repo, head).items() if name.startswith(prefix)}
    require(committed, "evidence directory has no committed files")
    entries = list(directory.rglob("*"))
    require(not any(path.is_symlink() for path in entries), "evidence directory contains a symlink")
    require(all(path.is_dir() or path.is_file() for path in entries), "evidence directory contains a special file")
    actual = {path.relative_to(repo).as_posix() for path in entries if path.is_file()}
    require(actual == set(committed), "evidence directory inventory differs from checked head")
    records = []
    for name, (mode, kind, oid) in sorted(committed.items()):
        path = repo / name
        require(kind == "blob" and mode in ("100644", "100755"), "evidence directory contains unsupported Git input")
        raw = bounded_read(path, MAX_LOG_BYTES if path.suffix == ".log" else MAX_JSON_BYTES)
        actual_mode = "100755" if path.stat().st_mode & 0o111 else "100644"
        require(actual_mode == mode and git(repo, "hash-object", "--stdin", data=raw).decode().strip() == oid,
                "evidence directory bytes/mode differ from checked head: " + name)
        if path.suffix != ".json":
            continue
        value = loads(raw.decode("utf-8"))
        if type(value) is dict and value.get("schema") == "trellis-qualification-run/1":
            validate_named("run-record", value)
            records.append((path, value))
        else:
            require(re.fullmatch(r"policy-[0-9a-f]{64}\.json", path.name) is not None,
                    "evidence directory contains unknown JSON: " + name)
            validate_named("requirements", value)
            require(path.name == "policy-" + digest(raw) + ".json", "evidence directory policy hash mismatch")
    require(records, "evidence directory contains no run records")
    return relative.as_posix(), records


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--requirements", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--receipt", type=Path, action="append", required=True)
    evidence = parser.add_mutually_exclusive_group()
    evidence.add_argument("--run-record", type=Path, action="append", default=[])
    evidence.add_argument("--evidence-dir", type=Path, help="complete committed recorder output directory, relative to --repo")
    args = parser.parse_args(argv)
    try:
        repo = args.repo.resolve()
        head = commit(repo, args.head)
        directory = None
        if args.evidence_dir is not None:
            directory, supplied = directory_records(repo, head, args.evidence_dir)
        else:
            supplied = []
            for path in args.run_record:
                require(not path.is_symlink(), "run record is a symlink")
                supplied.append((path, loads(bounded_read(path).decode("utf-8"))))
        records = {}
        for path, record in supplied:
            validate_named("run-record", record)
            require(record["run_id"] not in records, "duplicate run ID")
            records[record["run_id"]] = record, path
        requirements_bytes = bounded_read(args.requirements)
        require(requirements_bytes == blob(repo, head, POLICY_PATH), "requirements differ from committed policy")
        result = Checker(repo, head, loads(requirements_bytes.decode()), records).evaluate([read_receipt(path) for path in args.receipt])
        result["requirements_sha256"] = digest(requirements_bytes)
        result["requirements_path"] = POLICY_PATH
        if directory is not None:
            result.update(evidence_directory=directory, evidence_run_records=len(records))
    except Exception as error:
        result = dict(cells={}, benches={}, criteria={}, deferred={}, deferred_benches={}, deferred_bench_commands={}, summary=None,
                      release_eligible=False, all_criteria_pass=False, errors=[type(error).__name__ + ": " + str(error)])
    print(canonical(result))
    return 0 if result["release_eligible"] else 1


if __name__ == "__main__":
    sys.exit(main())
