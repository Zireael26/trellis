#!/usr/bin/env python3
"""Machine-local model roster administration. Only `probe` sends inference."""
import argparse
import copy
import datetime as dt
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
SKILL_REL = Path("core-rules/skills/herdr-foreman")
SKILL = Path(__file__).resolve().parent.parent / SKILL_REL
POOL = "opencode-go"
GO_PROVIDER = re.compile(re.escape(POOL) + r"(?:-([1-9][0-9]{0,5}))?\Z")
GO_ENDPOINT = "/zen/go/v1/chat/completions"
GO_MODEL = "deepseek-v4.1-flash"
WORKSPACE = re.compile(r"wrk_[A-Za-z0-9]{1,64}\Z")
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
IDENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\Z")
NATIVE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:+-]{0,119}\Z")
SECRET = re.compile(r"(?i)(?:^(?:sk[-_]|gh[pousr]_|github_pat_|xox[baprs]-|wrk_)|[A-Za-z0-9]{32,})")
EFFORTS = {"default", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}
REPLY_RESET = re.compile(r"(?i)\b(resets?\s+in\s+(?:[0-9]{1,6}\s*[dhms]\b\s*){1,4})")
AGY_PROVIDER = "anti" + "gravity"  # Legacy dispatch and OpenUsage identity.
QUOTA_KEYS = {
    "openai-codex": "codex", "openai": "codex", "codex": "codex",
    "anthropic": "claude", "claude": "claude", AGY_PROVIDER: AGY_PROVIDER,
    "google-" + AGY_PROVIDER: AGY_PROVIDER, "github-copilot": "copilot", "opencode": "opencode",
}
MAX_JSON = 2 * 1024 * 1024


class Refusal(ValueError):
    """A safe, operator-facing diagnostic; never include subprocess contents."""


def resolver_module():
    spec = importlib.util.spec_from_file_location("trellis_roster_resolver", SKILL / "scripts/resolve-roles.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def utcstamp():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def document(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as src:
        if not stat.S_ISREG(os.fstat(src.fileno()).st_mode):
            raise Refusal("JSON input must be a regular file")
        data = src.read(MAX_JSON + 1)
    if len(data) > MAX_JSON:
        raise Refusal("JSON input is too large")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise Refusal("expected a JSON object")
    return value


def identifier(value, pattern=IDENT):
    return isinstance(value, str) and pattern.fullmatch(value) and not SECRET.search(value)


def clean_id(value):
    if not identifier(value):
        raise Refusal("invalid identifier")
    return value


def private_directory(path):
    """Never follow or repair an unexpected local state directory."""
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise Refusal("roster state requires an owner-only directory (0700)")


class State:
    def __init__(self, resolver):
        self.resolver = resolver
        self.home = Path(resolver.trellis_home())
        self.roster = self.home / "roster.json"
        self.discovery = self.home / "state/roster-discovery.json"
        self.latch = self.home / "state/prepaid-latch.json"

    def current(self, required=True):
        if not os.path.lexists(self.roster):
            if required:
                raise Refusal("no machine roster; run trellis roster discover --write or migrate")
            return None, None
        return self.resolver.load_roster(str(self.roster))

    def prepare_state(self):
        private_directory(self.home)
        self.discovery.parent.mkdir(mode=0o700, exist_ok=True)
        self.check_state()

    def check_state(self):
        if os.path.lexists(self.discovery.parent):
            info = self.discovery.parent.lstat()
            # Older installs can have 0755 here, underneath the private home.
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise Refusal("unsafe roster state directory")

    def replace(self, doc, expected, backup=False):
        private_directory(self.home)
        # Use exactly the resolver's validation, before replacing the old file.
        with tempfile.TemporaryDirectory(prefix=".roster-", dir=self.home) as directory:
            candidate = str(Path(directory) / self.roster.name)
            self.resolver.write_private_json(candidate, doc)
            self.resolver.load_roster(candidate)
        _, observed = self.current(required=False)
        if observed != expected:
            raise Refusal("roster changed during this operation; retry")
        if backup and observed is not None:
            stamp = utcstamp().replace(":", "").replace(".", "-")
            os.link(self.roster, self.home / f"roster.json.bak-{stamp}", follow_symlinks=False)
        self.resolver.write_private_json(str(self.roster), doc)


def portable():
    return tuple(document(SKILL / f"{name}.json") for name in ("roles", "models", "harnesses"))


def fleet_name(value):
    name = value or os.environ.get("TRELLIS_FLEET_NAME") or os.environ.get("TRELLIS_FLEET") or "personal"
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", name):
        raise Refusal("invalid fleet name")
    return name


def fresh_roster(command, fleet):
    fleets = {"personal": {"allow": "*"}, "work": {"deny_pools": [POOL], "deny": ["opencode"]}}
    if fleet not in fleets:
        fleets[fleet] = {"allow": "*"}
    return {
        "schema_version": 1, "machine": {"label": "local", "verdict_host": True},
        "generated": {"by": f"trellis roster {command}", "at": utcstamp(), "reviewed": False},
        "routes": {}, "pools": {}, "fleets": fleets, "local_models": {}, "role_extensions": {},
    }


def _safe_cli_dir(path):
    try:
        resolved = Path(path).resolve(strict=True)
        info = os.stat(resolved)
    except OSError:
        return False
    uid = os.getuid()
    if not (stat.S_ISDIR(info.st_mode) and info.st_uid == uid and not (info.st_mode & 0o022)):
        return False
    for ancestor in resolved.parents:
        try:
            ainfo = os.stat(ancestor)
        except OSError:
            return False
        if ainfo.st_uid not in (uid, 0) or (ainfo.st_mode & 0o022):
            return False
    return True


def _nvm_version_key(path):
    name = path.parent.name.lstrip("v")
    parts = [int(p) if p.isdigit() else 0 for p in re.split(r"[.-]", name)[:3]]
    return tuple(parts), path.parent.name


def _augmented_path(base_path=None):
    """Append safe owner-owned CLI directories when running in real user HOME."""
    raw = os.environ.get("PATH", os.defpath) if base_path is None else base_path
    entries = [entry for entry in raw.split(os.pathsep) if entry]
    if os.environ.get("TRELLIS_ROSTER_NO_SYSTEM_FALLBACK"):
        return os.pathsep.join(entries)
    try:
        real_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
        current_home = Path.home().resolve()
    except (KeyError, OSError, RuntimeError):
        return os.pathsep.join(entries)
    if current_home != real_home:
        return os.pathsep.join(entries)
    candidates = [
        current_home / ".local" / "bin",
        current_home / ".npm-global" / "bin",
        Path("/opt/homebrew/bin"),
    ]
    nvm_root = current_home / ".nvm" / "versions" / "node"
    if nvm_root.is_dir():
        try:
            nvm_bins = [child / "bin" for child in nvm_root.iterdir() if (child / "bin").is_dir()]
            candidates.extend(sorted(nvm_bins, key=_nvm_version_key, reverse=True))
        except OSError:
            pass
    seen = set(entries)
    for candidate in candidates:
        text = str(candidate)
        if text not in seen and _safe_cli_dir(candidate):
            entries.append(text)
            seen.add(text)
    return os.pathsep.join(entries)


def _default_path():
    return os.pathsep.join(entry for entry in os.environ.get("PATH", os.defpath).split(os.pathsep) if entry)


def _which(name, search_path=None):
    raw = os.environ.get("PATH", os.defpath)
    if search_path is None:
        search_path = _augmented_path(raw)
    if search_path == raw:
        return shutil.which(name)
    found = shutil.which(name, path=search_path)
    if found and str(Path(found).parent) not in {e for e in raw.split(os.pathsep) if e}:
        try:
            info = os.stat(found)
        except OSError:
            return None
        if info.st_uid != os.getuid() or (info.st_mode & 0o022):
            return None
    return found


def run_query(argv, env=None, merge_stderr=False):
    """No stdin/TTY, no shell, bounded capture, and kill the group on timeout."""
    if env is None:
        search_path = _augmented_path()
        if search_path != _default_path():
            env = {**os.environ, "PATH": search_path}
    try:
        with tempfile.TemporaryFile() as output:
            with subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=output,
                                  stderr=subprocess.STDOUT if merge_stderr else subprocess.DEVNULL,
                                  start_new_session=True) as child:
                try:
                    if child.wait(timeout=15) != 0:
                        return None
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    return None
            output.seek(0)
            data = output.read(MAX_JSON + 1)
            if len(data) <= MAX_JSON:
                return ANSI.sub("", data.decode("utf-8", "replace"))
    except (OSError, ValueError):
        pass
    return None


def pi_auth():
    root = os.environ.get("PI_CODING_AGENT_DIR") or (Path.home() / ".pi/agent")
    path = Path(root) / "auth.json"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as src:
            info = os.fstat(src.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                return {}
            value = json.loads(src.read(MAX_JSON + 1))
            return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def api_key(auth, provider):
    entry = auth.get(provider)
    if isinstance(entry, dict) and entry.get("type") == "api_key":
        return entry.get("key")
    return None


def usable_key(key):
    return isinstance(key, str) and 0 < len(key) <= 4096 and all("!" <= char <= "~" for char in key)


def fingerprint(key):
    return hashlib.sha256(key.encode()).hexdigest()[:10]


def go_env(provider):
    match = GO_PROVIDER.fullmatch(provider)
    suffix = f"_{match[1]}" if match[1] is not None else ""
    return f"OPENCODE_GO{suffix}_API_KEY"


def go_member(provider, auth=None, env_only=False):
    match = GO_PROVIDER.fullmatch(provider)
    member = {"id": f"go-{match[1] or '1'}", "provider": provider,
              "credential_ref": f"pi-auth:{provider}", "env_only": env_only}
    if auth is not None:
        key = api_key(auth, provider)
        env_var = go_env(provider)
        if not usable_key(key) and usable_key(os.environ.get(env_var)):
            key = os.environ[env_var]
            member["credential_ref"] = f"env:{env_var}"
        if usable_key(key):
            member["key_sha256_10"] = fingerprint(key)
    return member


def visible_secrets(auth):
    # Only used to discard accidental echoes interleaved with a model listing.
    values = {value for name, value in os.environ.items()
              if re.search(r"(?i)(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)", name) and value}
    for provider, entry in auth.items():
        key = api_key(auth, provider)
        if usable_key(key):
            values.add(key)
        if isinstance(entry, dict):
            values.update(value for field, value in entry.items() if field in {"access", "refresh", "token"}
                          and isinstance(value, str) and value)
    return values


def listing(text, harness, secrets):
    """Extract model identifiers, not arbitrary stdout or informational lines."""
    if not text:
        return []
    rows = set()
    header = False
    for line in text.splitlines():
        parts = line.strip().split()
        if not parts:
            continue
        if harness == "pi":
            if [part.lower() for part in parts[:2]] in (["provider", "model"], ["provider", "id"]):
                header = True
                continue
            if len(parts) < 2:
                provider, split, native = parts[0].partition("/")
                if not split:
                    continue
            elif header or len(parts) == 2 or (len(parts) > 3 and parts[2][0].isdigit()):
                provider, native = parts[:2]
            else:
                continue
        elif harness == "opencode":
            if len(parts) != 1:
                continue
            provider, split, native = parts[0].partition("/")
            if not split:
                continue
        elif harness == "agy":
            native = parts[0]
            if native.casefold().rstrip(":") in {"auto", "models", "available", "model", "id", "fetching"}:
                continue
            if len(parts) < 2 or not re.search(r"(?:\t| {2,})", line.strip()):
                continue
            provider = AGY_PROVIDER
        else:
            if parts[0] in {"-", "*", "•"}:
                parts = parts[1:]
            if not parts or (len(parts) > 1 and parts[1] not in {"-", "–", "—", "(default)"}):
                continue
            provider, native = "cursor", parts[0]
            if native.casefold().rstrip(":") in {"auto", "models", "available", "model", "id"}:
                continue
        if (identifier(provider) and identifier(native, NATIVE) and
                provider.casefold() not in {"api-key", "apikey", "authorization", "bearer", "credential", "key",
                                            "secret", "token", "warning", "error"} and not any(
                candidate == secret or (len(secret) >= 8 and secret in candidate)
                for candidate in (provider, native) for secret in secrets)):
            rows.add((provider, native))
    return sorted(rows)


def match_model(kb, harness, provider, native):
    """Exact canonical model and effort, or no match. Never infer a family."""
    value = native
    if harness == "opencode" and provider == "opencode" and value.endswith("-free"):
        value = value[:-5]
    matches = {(value, None)} if value in kb["models"] else set()
    for token in EFFORTS | {"thinking"}:
        for sep in (":", "-"):
            suffix = sep + token
            if not value.endswith(suffix):
                continue
            base = value[:-len(suffix)]
            facts = kb["models"].get(base, {})
            effort = facts.get("default_effort") if token == "thinking" else token
            if effort in facts.get("efforts", ()):
                matches.add((base, effort))
    if len(matches) != 1:
        return [], native
    model, effort = matches.pop()
    if effort is None and harness != "pi":
        facts = kb["models"][model]
        effort = facts.get("default_effort")
        if effort is None and len(facts["efforts"]) == 1:
            effort = facts["efforts"][0]
        if effort is None:
            return [], native
    seats = [seat for seat, facts in kb["seats"].items()
             if facts["model"] == model and (effort is None or facts["effort"] == effort)]
    return seats, native.rsplit(":", 1)[0] if harness == "pi" and effort is not None else native


def quota_for(harness, provider, metered=None):
    if metered in {"prepaid", "unmetered"}:
        return {"source": "none"}
    key = "claude" if harness == "claude-code" else QUOTA_KEYS.get(provider)
    return {"source": "openusage", "provider_key": key} if key else {"source": "none"}


def route_key(route):
    return tuple(route.get(field) for field in ("harness", "provider", "pool", "native_model"))


def add_route(doc, seat, route):
    routes = doc["routes"].setdefault(seat, [])
    if not any(route_key(old) == route_key(route) for old in routes):
        routes.append(route)


def pool_doc(members):
    return {"selector": "hrw-v1", "max_concurrency_per_member": 4, "members": members}


def verified_flags(binary, adapter):
    flags = [arg for arg in adapter.get("argv", ()) if arg.startswith("-")]
    output = run_query([binary, "--help"], merge_stderr=True) if flags else ""
    return output is not None and all(re.search(rf"(?<![\w-]){re.escape(flag)}(?![\w-])", output) for flag in flags)


def discover_inventory(kb, adapters):
    auth = pi_auth()
    secrets = visible_secrets(auth)
    search_path = _augmented_path()
    listings, health, proposals = [], {}, []
    for harness in ("pi", "claude-code", "codex", "cursor", "agy", "opencode"):
        adapter = adapters["harnesses"].get(harness, {})
        binary = next((found for name in adapter.get("bin", []) if (found := _which(name, search_path))), None)
        if binary is None:
            health[harness] = "no-harness"
            continue
        health[harness] = "not-listed"
        parsed, env_only = [], set()
        auth_ok, flags_ok = True, True
        auth_probe = None
        if harness == "pi":
            parsed = listing(run_query([binary, "--list-models"]), harness, secrets)
            minimal = {"HOME": os.environ.get("HOME") or str(Path.home()), "PATH": search_path}
            clean = run_query([binary, "--list-models"], env=minimal)
            if clean is not None:
                env_only = {row[0] for row in parsed} - {row[0] for row in listing(clean, harness, secrets)}
            else:
                auth_ok = False  # Cannot classify environment reliance from a failed comparison.
        elif harness == "claude-code":
            if sys.platform == "darwin" and (security := _which("security", search_path)):
                auth_probe = ["security", "find-generic-password", "-s", "Claude Code-credentials"]
                auth_ok = run_query([security, *auth_probe[1:]]) is not None
            else:
                auth_ok = (Path.home() / ".claude/.credentials.json").is_file()
        elif harness == "codex":
            auth_probe = ["codex", "login", "status"]
            auth_ok = run_query([binary, *auth_probe[1:]]) is not None
        elif harness == "agy":
            auth_ok = run_query([binary, "--version"]) is not None
            if auth_ok:
                parsed = listing(run_query([binary, "models"]), harness, secrets)
        elif harness == "cursor":
            auth_probe = [Path(binary).name, "status"]
            auth_ok = run_query([binary, "status"]) is not None
            parsed = listing(run_query([binary, "models"]), harness, secrets)
            if not parsed:
                parsed = listing(run_query([binary, "--list-models"]), harness, secrets)
            if not parsed:
                health[harness] = "models_unlisted"
        elif harness == "opencode":
            auth_ok = run_query([binary, "auth", "list"]) is not None
            parsed = listing(run_query([binary, "models"]), harness, secrets)
        if harness in {"codex", "cursor", "opencode", "agy"}:
            flags_ok = verified_flags(binary, adapter)
        if not auth_ok:
            health[harness] = "no-credential"
        elif not flags_ok:
            health[harness] = "harness-flag-unverified"
        elif parsed:
            health[harness] = "listed"
        for provider, native in parsed:
            seats, launch_model = match_model(kb, harness, provider, native)
            row = {"harness": harness, "provider": provider, "native_model": native,
                   "seats": seats, "env_only": provider in env_only,
                   "confirmed": auth_ok and flags_ok, "auth_probe": auth_probe, "verified_flags": flags_ok,
                   "opportunistic": harness == "opencode" and provider == "opencode" and native.endswith("-free")}
            listings.append(row)
            for seat in seats:
                if harness == "agy" and kb["models"][kb["seats"][seat]["model"]]["family"] != "google":
                    continue
                if kb["seats"][seat].get("verdict_only") and harness not in {"claude-code", "cursor"}:
                    continue
                proposals.append((seat, {**row, "native_model": launch_model}))
        family = {"claude-code": "anthropic", "codex": "openai", "agy": "google"}.get(harness)
        if family and auth_ok and not parsed:
            provider = {"claude-code": "anthropic", "codex": "codex", "agy": AGY_PROVIDER}[harness]
            for seat, facts in kb["seats"].items():
                model = facts["model"]
                if kb["models"][model]["family"] != family:
                    continue
                if harness == "claude-code" and (facts["effort"] not in {"low", "medium", "high"} or
                        not model.startswith(("claude-opus-", "claude-sonnet-", "claude-haiku-"))):
                    continue
                proposals.append((seat, {"harness": harness, "provider": provider, "native_model": model,
                                        "confirmed": False, "env_only": False, "auth_probe": auth_probe,
                                        "verified_flags": flags_ok}))
    return proposals, listings, health, auth


def route_from_listing(row, fleet):
    harness, provider = row["harness"], row["provider"]
    route = {"harness": harness, "provider": provider, "native_model": row["native_model"],
             "confirmed": row["confirmed"], "env_only": row["env_only"],
             "opportunistic": row.get("opportunistic", False), "quota": quota_for(harness, provider)}
    if row.get("auth_probe"):
        route["auth_probe"] = row["auth_probe"]
    if harness not in {"pi", "claude-code"} and "verified_flags" in row:
        route["verified_flags"] = row["verified_flags"]
    if fleet == "work" and harness in {"claude-code", "cursor", "codex"}:
        route["fleets"] = ["work"]
    if route["opportunistic"]:
        route["fleets"] = ["personal"]
    return route


RETIRED_SEATS = frozenset({"argon", "sol-max", "hydrogen-medium", "hydrogen-high"})


def discovery_proposal(current, proposals, auth, fleet):
    doc = copy.deepcopy(current) if current is not None else fresh_roster("discover", fleet)
    local_seats = {
        facts.get("seat") for facts in doc.get("local_models", {}).values()
        if isinstance(facts, dict)
    }
    for retired in RETIRED_SEATS - local_seats:
        doc.get("routes", {}).pop(retired, None)
    for pool in doc.get("pools", {}).values():
        if isinstance(pool, dict):
            for member in pool.get("members", ()):
                if isinstance(member, dict) and isinstance(member.get("seats"), list):
                    member["seats"] = [s for s in member["seats"] if s not in (RETIRED_SEATS - local_seats)]
    go = {}
    for seat, row in proposals:
        provider = row["provider"]
        if row["harness"] == "pi" and GO_PROVIDER.fullmatch(provider):
            go.setdefault(provider, {})[(seat, row["native_model"])] = row
            continue
        route = route_from_listing(row, fleet)
        if row["harness"] == "pi" and isinstance(auth.get(provider), dict):
            route["credential_ref"] = f"pi-auth:{provider}"
        matches = [old for old in doc["routes"].get(seat, []) if route_key(old) == route_key(route)]
        if matches:
            # Environment dependence is an observation, not a billing or plan assertion.
            if row["harness"] == "pi" and row["confirmed"]:
                matches[0]["env_only"] = row["env_only"]
        else:
            add_route(doc, seat, route)
    pools = doc.setdefault("pools", {})
    providers = sorted(go, key=lambda p: (int(GO_PROVIDER.fullmatch(p)[1] or 1), p))
    members = {p: go_member(p, auth, any(row["env_only"] for row in go[p].values())) for p in providers}
    if len({m["id"] for m in members.values()}) != len(members):
        raise Refusal("ambiguous Go provider numbering")
    # Coverage is indexed by seat, so each pooled seat uses one native ID.
    selected = {}
    for seat, model in sorted({pair for rows in go.values() for pair in rows}):
        serving = [p for p in providers if (seat, model) in go[p]]
        if seat not in selected or len(serving) > len(selected[seat][1]):
            selected[seat] = (model, serving)
    if POOL in pools:
        # Keep operator-reviewed choices; refresh observed environment and keys.
        for member in pools[POOL]["members"]:
            observed = members.get(member["provider"])
            if not observed or not any(row["confirmed"] for row in go[member["provider"]].values()):
                continue
            member["env_only"] = observed["env_only"]
            if member.get("credential_ref") == observed["credential_ref"] and observed.get("key_sha256_10"):
                if observed["key_sha256_10"] != member.get("key_sha256_10"):
                    member.pop("account", None)
                member["key_sha256_10"] = observed["key_sha256_10"]
        return doc
    if selected:
        coverage = {p: sorted(seat for seat, (_, serving) in selected.items() if p in serving) for p in providers}
        pools[POOL] = pool_doc([{**members[p], "seats": coverage[p]} for p in providers if coverage[p]])
        for seat, (model, serving) in selected.items():
            add_route(doc, seat, {"harness": "pi", "pool": POOL, "native_model": model, "confirmed": False,
                                 "env_only": all(members[p]["env_only"] for p in serving),
                                 "opportunistic": False, "quota": {"source": "none"}})
    return doc


def discover(args, state):
    _, kb, adapters = portable()
    fleet = state.resolver.active_fleet(args.fleet)
    current, sha = state.current(required=False)
    proposals, listings, health, auth = discover_inventory(kb, adapters)
    doc = discovery_proposal(current, proposals, auth, fleet)
    state.prepare_state()
    # These rows are the parsed inventory. No raw output or secret-bearing argv.
    for row in listings:
        row.pop("auth_probe", None)
    report = {"schema_version": 1, "at": utcstamp(), "fleet": fleet, "harnesses": health,
              "listed": [r for r in listings if r["seats"]],
              "unclassified": [r for r in listings if not r["seats"]]}
    state.resolver.write_private_json(str(state.discovery), report)
    for seat, routes in sorted(doc["routes"].items()):
        old = (current or {}).get("routes", {}).get(seat, [])
        for route in routes:
            if route in old:
                continue
            where = route.get("pool", route.get("provider", route["harness"]))
            flags = [label for label, present in (("unconfirmed", not route.get("confirmed", True)),
                     ("env-only", route.get("env_only")), ("opportunistic", route.get("opportunistic"))) if present]
            mark = "~" if any(route_key(r) == route_key(route) for r in old) else "+"
            print(f"{mark} {seat}: {route['harness']}/{where}" + (f" ({', '.join(flags)})" if flags else ""))
    for provider in sorted({row["provider"] for row in listings if row["env_only"]}):
        print(f"! {provider}: env-only")
    for name, pool in sorted(doc.get("pools", {}).items()):
        before = (current or {}).get("pools", {}).get(name, {}).get("members", [])
        for member in pool["members"]:
            if member not in before:
                verification = "workspace verified" if member.get("account") not in (None, "<probe>") else "workspace unverified"
                print(f"~ {name}/{member['id']}: {verification}")
    print(f"Discovery recorded; {len(report['unclassified'])} unclassified model(s).")
    if args.write:
        state.replace(doc, sha, backup=True)
        print("Roster written. Review unconfirmed routes and their quota before use.")
    else:
        print("Dry run: roster unchanged.")


def legacy_policy(state, explicit):
    if explicit:
        policy = document(explicit)
        if not isinstance(policy.get("agents"), dict) or not policy["agents"]:
            raise Refusal("expected a legacy roles policy with inline agents")
        return policy
    releases = state.home.resolve() / "releases"
    if releases.is_symlink():
        raise Refusal("release store is a symlink; specify migrate --roles PATH")
    try:
        versions = [child for child in releases.iterdir() if not child.is_symlink() and
                    re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", child.name)]
    except FileNotFoundError:
        versions = []
    for release in sorted(versions, key=lambda p: tuple(map(int, p.name.split("."))), reverse=True):
        path = release / "payload" / SKILL_REL / "roles.json"
        if path.resolve() != path.absolute() or not path.is_file():
            continue
        doc = document(path)
        if isinstance(doc.get("agents"), dict) and doc["agents"]:
            return doc
    raise Refusal("no installed legacy policy; specify migrate --roles PATH")


def legacy_native(facts, provider):
    model = facts.get("native_model", facts.get("model", ""))
    if not isinstance(model, str):
        return ""
    if model.startswith(provider + "/"):
        model = model[len(provider) + 1:]
    if model.endswith(":" + str(facts.get("effort"))):
        model = model.rsplit(":", 1)[0]
    return model


def migrate(args, state):
    if state.current(required=False)[0] is not None:
        raise Refusal("a roster already exists; migration will not replace it")
    if args.roles and args.path:
        raise Refusal("supply only one legacy policy path")
    legacy = legacy_policy(state, args.roles or args.path)
    kb = document(SKILL / "models.json")
    adapters = document(SKILL / "harnesses.json")["harnesses"]
    doc = fresh_roster("migrate", state.resolver.active_fleet(args.fleet))
    go_routes, members, omitted = {}, {}, 0
    auth = None  # Read Pi metadata only when this policy actually has Go rows.
    chain_meta = {}
    for role in legacy.get("roles", {}).values():
        for row in role.get("chain", ()):
            for field in ("auth_probe", "opportunistic", "live_probe"):
                if field in row:
                    values = chain_meta.setdefault(row["agent"], {}).setdefault(field, [])
                    if row[field] not in values:
                        values.append(row[field])
    for agent, facts in legacy["agents"].items():
        provider, harness = facts.get("provider"), facts.get("harness", "pi")
        if not identifier(provider) or harness not in adapters:
            omitted += 1
            continue
        native = legacy_native(facts, provider)
        if not identifier(native, NATIVE):
            omitted += 1
            continue
        go = harness == "pi" and GO_PROVIDER.fullmatch(provider)
        seat = agent
        canonical = kb["seats"].get(seat)
        if go and canonical is None:
            fits = [alias for alias, fact in kb["seats"].items()
                    if fact["model"] == native and fact["effort"] == facts.get("effort")]
            if len(fits) == 1:
                seat = fits[0]
                canonical = kb["seats"][seat]
        if not canonical or (canonical["model"], canonical["effort"]) != (native, facts.get("effort")):
            omitted += 1
            continue
        route = {"harness": harness, "provider": provider, "native_model": native,
                 "confirmed": facts.get("confirmed", True), "env_only": facts.get("env_only", False),
                 "quota": facts.get("quota", quota_for(harness, provider, facts.get("metered")))}
        for field in ("metered", "live_probe", "auth_probe", "opportunistic", "credential_ref", "fleets", "verified_flags"):
            if field in facts:
                route[field] = facts[field]
        for field, values in chain_meta.get(agent, {}).items():
            if field == "auth_probe" and len(values) != 1:
                raise Refusal("legacy policy has role-specific conflicting probes; migrate these routes manually")
            route[field] = values[0] if field == "auth_probe" else bool(route.get(field) or any(values))
        if go:
            if auth is None:
                auth = pi_auth()
            member = go_member(provider, auth, env_only=route["env_only"])
            if "credential_ref" in route:
                if route["credential_ref"] not in {f"pi-auth:{provider}", f"env:{go_env(provider)}"}:
                    raise Refusal("legacy policy Go route carries a foreign credential_ref")
                member["credential_ref"] = route["credential_ref"]
                member.pop("key_sha256_10", None)
            key = credential(member, auth)
            if usable_key(key):
                member["key_sha256_10"] = fingerprint(key)
            elif "key_sha256_10" in facts:
                member["key_sha256_10"] = facts["key_sha256_10"]
            if "auth_probe" in route:
                member["auth_probe"] = route["auth_probe"]
            members.setdefault(provider, []).append(member)
            go_routes.setdefault(seat, []).append(route)
        else:
            add_route(doc, seat, route)
    pool_members = []
    # Route-level facts that cannot be represented by one common pool route
    # keep their original direct routes rather than silently changing policy.
    if all(all(m == rows[0] for m in rows) for rows in members.values()):
        pool_members = sorted((rows[0] for rows in members.values()), key=lambda m: int(m["id"].split("-")[1]))
        if len({m["id"] for m in pool_members}) != len(pool_members):
            raise Refusal("ambiguous Go provider numbering")
    member_fields = {"provider", "credential_ref", "auth_probe", "env_only"}
    coverage = {member["provider"]: [] for member in pool_members}
    for seat, routes in go_routes.items():
        common = [{k: v for k, v in route.items() if k not in member_fields} for route in routes]
        if pool_members and all(route == common[0] for route in common):
            for provider in {r["provider"] for r in routes}:
                coverage[provider].append(seat)
            add_route(doc, seat, {**common[0], "pool": POOL, "env_only": all(r["env_only"] for r in routes)})
        else:
            for route in routes:
                add_route(doc, seat, route)
                if route["provider"] not in doc["fleets"]["work"]["deny"]:
                    doc["fleets"]["work"]["deny"].append(route["provider"])
    if any(coverage.values()):
        doc["pools"][POOL] = pool_doc([{**member, "seats": sorted(coverage[member["provider"]])}
                                      for member in pool_members if coverage[member["provider"]]])
    if not doc["routes"]:
        raise Refusal("legacy policy contains no routes matching this release")
    state.replace(doc, None)
    print(f"Migrated {len(doc['routes'])} seat(s); {omitted} legacy row(s) not mapped. No accounts verified.")


def effective(args, state, required=True):
    doc, _ = state.current(required=required)
    cfg, models, harnesses = portable()
    state.check_state()
    hydrated = state.resolver.hydrate_catalog(cfg, models=models, roster=doc, harnesses=harnesses,
                                             fleet=state.resolver.active_fleet(args.fleet), latch_file=str(state.latch))
    return doc or {}, models, hydrated


def show(args, state):
    doc, _, hydrated = effective(args, state)
    ceiling = state.resolver.topology(hydrated)
    pools = state.resolver.pool_status(hydrated)
    for name, health in pools.items():
        health["unverified"] = sorted(member["id"] for member in doc["pools"][name]["members"]
                                      if not WORKSPACE.fullmatch(member.get("account", "")))
    fields = ("model", "family", "effort", "harness", "provider", "pool", "launcher", "capabilities",
              "metered", "confirmed", "env_only", "opportunistic", "route_refusal", "not_on_machine")
    def public_facts(facts):
        row = {field: facts[field] for field in fields if field in facts}
        if "_route_refusal" in facts:
            row["route_refusal"] = facts["_route_refusal"]
        return row

    agents = {seat: {**public_facts(facts), "routes": [public_facts(route) for route in facts.get("_variants", [])]}
              for seat, facts in hydrated.get("agents", {}).items()}
    if args.json:
        print(json.dumps({"agents": agents, "topology": ceiling, "pools": pools}, sort_keys=True, indent=2))
        return
    print("Families: " + (", ".join(ceiling.get("families", [])) or "none"))
    for family, roles in sorted(ceiling.get("unfillable", {}).items()):
        if roles:
            print(f"DEGRADED (topology) beside {family}: " + ", ".join(roles))
    for seat, facts in sorted(agents.items()):
        tags = [tag for tag in (facts.get("route_refusal"), "env-only" if facts.get("env_only") else None) if tag]
        route = facts.get("model") or facts.get("pool")
        print(f"{seat}: {route or (tags.pop(0) if tags else 'not-on-machine')}" +
              (f" ({', '.join(tags)})" if tags else ""))
    for name, health in sorted(pools.items()):
        print(f"{name}: healthy {', '.join(health.get('healthy', [])) or 'none'}")
        if health["unverified"]:
            print("  workspace unverified: " + ", ".join(health["unverified"]))
        for member, latch in sorted(health.get("latched", {}).items()):
            print(f"  {member}: latched until {latch.get('resets_at', 'unknown')}")


def discovery_report(state):
    state.check_state()
    if os.path.lexists(state.discovery):
        return state.resolver.private_json(str(state.discovery))[0]
    return {}


def gaps(args, state):
    doc, kb, hydrated = effective(args, state, required=False)
    report = discovery_report(state)
    agents = hydrated.get("agents", {})
    reasons = {}
    for seat in kb["seats"]:
        facts = agents.get(seat, {})
        reason = facts.get("_route_refusal")
        if reason and reason != "not-on-machine":
            reasons[seat] = reason
        elif facts.get("env_only"):
            reasons[seat] = "env-only"
        elif not facts or facts.get("not_on_machine") or reason or not facts.get("harness"):
            listed = [r for r in report.get("listed", []) if seat in r.get("seats", [])]
            routes = doc["routes"].get(seat, [])
            health = report.get("harnesses", {})
            family = kb["models"][kb["seats"][seat]["model"]]["family"]
            proposal_harness = {"anthropic": "claude-code", "openai": "codex", "google": "agy"}.get(family)
            expected = [r["harness"] for r in routes or listed]
            if not expected and proposal_harness:
                expected = [proposal_harness, "pi", "cursor", "opencode"]
            statuses = {health.get(name) for name in expected} if expected else set(health.values())
            reasons[seat] = ("env-only" if listed and all(r.get("env_only") for r in listed) else
                             "no-credential" if "no-credential" in statuses and
                             (routes or listed or statuses <= {"no-credential", "no-harness"}) else
                             "no-harness" if statuses == {"no-harness"} else "not-listed")
    for seat, reason in sorted(reasons.items()):
        facts = kb["seats"][seat]
        family = kb["models"][facts["model"]]["family"]
        alternatives = sorted((other for other, f in kb["seats"].items() if other not in reasons and
                               kb["models"][f["model"]]["family"] == family),
                              key=lambda other: (kb["seats"][other]["model"] != facts["model"], other))
        print(f"{seat}: {reason}; nearest {family}: {alternatives[0] if alternatives else 'none'}")
    for row in report.get("unclassified", []):
        if identifier(row.get("native_model"), NATIVE) and identifier(row.get("harness")):
            print(f"{row['harness']}/{row['native_model']}: unclassified")


def classify(args, state):
    doc, sha = state.current()
    _, kb, _ = portable()
    if not identifier(args.model, NATIVE):
        raise Refusal("invalid model identifier")
    seat, family = clean_id(args.seat or args.model), clean_id(args.family)
    known_caps = {cap for facts in kb["seats"].values() for cap in facts["capabilities"]}
    capabilities = sorted(set(cap for item in args.capabilities for cap in item.split(",")))
    if not capabilities or not set(capabilities) <= known_caps:
        raise Refusal("capabilities must be drawn from the portable catalog")
    if seat in kb["seats"] or seat in doc.get("routes", {}) or args.model in kb["models"] or args.model.casefold() == "auto":
        raise Refusal("classification cannot replace a known seat or route auto")
    inventory = discovery_report(state)
    rows = [row for row in inventory.get("unclassified", [])
            if row.get("native_model") == args.model and (not args.harness or row.get("harness") == args.harness)
            and (not args.provider or row.get("provider") == args.provider)]
    if not rows:
        raise Refusal("model not found in unclassified inventory; run discover first")
    if len({(r["harness"], r["provider"]) for r in rows}) > 1:
        raise Refusal("ambiguous model; specify --harness and/or --provider")
    if args.model in doc.get("local_models", {}) or any(facts["seat"] == seat for facts in doc.get("local_models", {}).values()):
        raise Refusal("model is already classified")
    effort = args.effort
    doc.setdefault("local_models", {})[args.model] = {"family": family, "efforts": [effort],
                                                      "seat": seat, "capabilities": capabilities}
    for row in rows:
        route = route_from_listing(row, fleet_name(inventory.get("fleet")))
        if row["harness"] == "pi" and GO_PROVIDER.fullmatch(row["provider"]):
            raise Refusal("classify cannot add unverified models to the Go pool")
        route["confirmed"] = False  # Family classification is not a quota/auth assertion.
        add_route(doc, seat, route)
    state.replace(doc, sha, backup=True)
    print(f"Classified {seat} as {family}; confirm its route and quota before use.")


def locate_member(doc, name, pool):
    matches = [(key, m) for key, spec in doc.get("pools", {}).items() if not pool or key == pool
               for m in spec["members"] if name in (m["id"], m["provider"],
                                                    f"{key}/{m['id']}", f"{key}/{m['provider']}")]
    if len(matches) != 1:
        raise Refusal("unknown or ambiguous pool member")
    return matches[0]


def limit_message(message):
    """Retain reset facts only, never the body or a user-supplied secret."""
    lower = message.lower()
    kind = "monthly " if "month" in lower else "5-hour " if "hour" in lower else ""
    reset = REPLY_RESET.search(message)
    evidence = "GoUsageLimitError " if "GoUsageLimitError" in message else ""
    return evidence + kind + (reset[1] if reset else "")


def manual_latch(args, state):
    doc, _ = state.current()
    pool, member = locate_member(doc, args.member, args.pool)
    state.prepare_state()
    if args.command == "unlatch":
        if not args.reason or not args.reason.strip():
            raise Refusal("unlatch requires a nonempty reason")
        changed = state.resolver.unlatch(doc, str(state.latch), f"{pool}/{member['id']}", args.reason)
        print("Latch cleared." if changed else "No matching latch.")
        return
    message = args.message or ""
    if args.message_file:
        fd = os.open(args.message_file, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as src:
            if not stat.S_ISREG(os.fstat(src.fileno()).st_mode):
                raise Refusal("message file must be a regular file")
            message = src.read(MAX_JSON).decode("utf-8", "replace")
    entry = state.resolver.report_limit(doc, str(state.latch), f"{pool}/{member['provider']}",
                                        limit_message(message), writer="roster-latch")
    print(f"Latched until {entry['resets_at']} ({entry['reset_source']}).")


def credential(member, auth):
    ref = member.get("credential_ref", "")
    kind, _, name = ref.partition(":")
    provider = member.get("provider", "")
    if kind == "pi-auth" and name == provider:
        return api_key(auth, name)
    if kind == "env" and GO_PROVIDER.fullmatch(provider) and name == go_env(provider):
        return os.environ.get(name)
    return None


def go_request(key):
    # Direct TLS with system verification: no proxy, redirects, or roster URL.
    connection = http.client.HTTPSConnection("opencode.ai", timeout=10)
    data = json.dumps({"model": GO_MODEL, "max_tokens": 1, "messages": [{"role": "user", "content": "Reply OK"}]})
    try:
        connection.request("POST", GO_ENDPOINT, body=data, headers={"Authorization": f"Bearer {key}",
                           "Content-Type": "application/json", "x-opencode-session": f"probe-{uuid.uuid4()}"})
        with connection.getresponse() as response:
            payload = response.read(65537)
            return response.status, payload.decode("utf-8", "replace") if len(payload) <= 65536 else ""
    finally:
        connection.close()


def workspace(body, status):
    if status != 429 and not 200 <= status < 300:
        return None
    try:
        reply = json.loads(body)
    except ValueError:
        reply = None
    found = set()
    pending = [reply] if isinstance(reply, dict) else []
    # Do not search successful generated completion text or arbitrary payloads.
    while pending:
        obj = pending.pop()
        for field, value in obj.items():
            if field in {"workspace", "workspaceID", "workspaceId", "workspace_id"}:
                if isinstance(value, dict):
                    value = value.get("id")
                if isinstance(value, str) and WORKSPACE.fullmatch(value):
                    found.add(value)
            elif field in {"error", "metadata", "data"} and isinstance(value, dict):
                pending.append(value)
    if status == 429:
        found.update(re.findall(r"\bwrk_[A-Za-z0-9]{1,64}\b", body))
    return next(iter(found)) if len(found) == 1 else None


def probe(args, state):
    if args.pool != POOL:
        raise Refusal("the inference probe supports only the OpenCode Go pool")
    doc, sha = state.current()
    pool = doc.get("pools", {}).get(args.pool)
    if not pool or not pool["members"]:
        raise Refusal("no Go pool members to probe")
    state.prepare_state()
    auth = pi_auth()
    results, limits, failed, changed = [], [], False, False
    for member in pool["members"]:
        name = member["id"]
        # The selected pool is Go-only; do not send a different provider's key.
        if not GO_PROVIDER.fullmatch(member["provider"]):
            results.append(f"{name}: not an OpenCode Go provider")
            failed = True
            continue
        key = credential(member, auth)
        if not usable_key(key):
            results.append(f"{name}: missing or unsupported credential reference")
            failed = True
            continue
        key_hash = fingerprint(key)
        if key_hash != member.get("key_sha256_10"):
            member.pop("account", None)
            member["key_sha256_10"] = key_hash
            changed = True
        try:
            status, body = go_request(key)
            account = workspace(body, status)
        except (OSError, ValueError, http.client.HTTPException, RecursionError):
            results.append(f"{name}: request failed")
            failed = True
            continue
        if account and account != member.get("account"):
            member["account"] = account
            changed = True
        if status == 429:
            limits.append((name, f"{args.pool}/{member['provider']}", limit_message(body)))
        elif not 200 <= status < 300:
            failed = True
        results.append(f"{name}: HTTP {status}; " + ("workspace returned" if account else "no workspace returned"))
    if changed:
        state.replace(doc, sha, backup=True)
    for name, provider, message in limits:
        try:
            state.resolver.report_limit(doc, str(state.latch), provider, message, writer="roster-probe")
        except (OSError, ValueError):
            results.append(f"{name}: could not write latch")
            failed = True
    for line in results:
        print(line)
    accounts = [m["account"] for m in pool["members"] if m.get("account")]
    if len(accounts) != len(set(accounts)):
        print("Warning: pool members share a workspace; they do not provide independent quota.")
    return int(failed)


def parser():
    base = argparse.ArgumentParser(description=__doc__)
    commands = base.add_subparsers(dest="command", required=True)
    discover_cmd = commands.add_parser("discover", help="inventory installed harnesses without inference")
    discover_cmd.add_argument("--fleet")
    discover_cmd.add_argument("--write", action="store_true", help="write proposals to the private roster")
    show_cmd = commands.add_parser("show", help="show effective routes, topology and pool health")
    show_cmd.add_argument("--json", action="store_true")
    show_cmd.add_argument("--fleet")
    commands.add_parser("gaps", help="explain missing seats").add_argument("--fleet")
    commands.add_parser("probe", help="send ONE paid inference canary per Go pool member").add_argument("--pool", default=POOL)
    latch_cmd = commands.add_parser("latch", help="manually latch a pool member")
    latch_cmd.add_argument("member")
    latch_cmd.add_argument("--pool")
    message = latch_cmd.add_mutually_exclusive_group()
    message.add_argument("--message")
    message.add_argument("--message-file")
    unlatch_cmd = commands.add_parser("unlatch", help="clear a member's latch with an audit reason")
    unlatch_cmd.add_argument("member")
    unlatch_cmd.add_argument("--pool")
    unlatch_cmd.add_argument("--reason", required=True)
    classify_cmd = commands.add_parser("classify", help="classify an exact model from the last inventory")
    classify_cmd.add_argument("model")
    classify_cmd.add_argument("--family", required=True)
    classify_cmd.add_argument("--capabilities", nargs="+", required=True)
    classify_cmd.add_argument("--seat")
    classify_cmd.add_argument("--effort", choices=sorted(EFFORTS), default="default")
    classify_cmd.add_argument("--harness")
    classify_cmd.add_argument("--provider")
    migrate_cmd = commands.add_parser("migrate", help="convert a legacy inline-agents roles policy")
    migrate_cmd.add_argument("path", nargs="?", metavar="LEGACY_ROLES")
    migrate_cmd.add_argument("--roles", "--legacy-roles", metavar="PATH")
    migrate_cmd.add_argument("--fleet")
    return base


def main():
    args = parser().parse_args()
    handlers = {"discover": discover, "show": show, "gaps": gaps, "probe": probe,
                "latch": manual_latch, "unlatch": manual_latch, "classify": classify, "migrate": migrate}
    try:
        return handlers[args.command](args, State(resolver_module())) or 0
    except Refusal as exc:
        print(f"trellis roster: {exc}", file=sys.stderr)
    except (OSError, ValueError, RuntimeError, KeyError, AttributeError, TypeError, ImportError):
        print("trellis roster: invalid or unavailable roster, state, or release policy (check schema and permissions)",
              file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
