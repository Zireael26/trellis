"""Exact-input passing test verdicts.

run-tests-local writes full-battery verdicts under verdicts/; process-gate writes
verdicts for any other project test command under the Trellis-guarded
$TRELLIS_HOME/state/gate-verdicts/. Both key on the committed tree, the test
command, the runner, the toolchain, the platform and the keyed environment, so
a pass transfers between checkouts and sessions of one host.
"""
from __future__ import annotations

import configparser
import fcntl
import fnmatch
import importlib.util
import json
import math
import os
import posixpath
from pathlib import Path
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any

try:
    import tomllib
except ImportError:  # Python < 3.11: a pyproject is then read whole.
    tomllib = None  # type: ignore[assignment]

# `python3 -I` does not put the script directory on sys.path.
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
from gate_receipts import digest, passing_rows, private, state_root
from receipt_provenance import probe as _receipt_probe


PROBE_TIMEOUT_SECONDS = 5


def probe(command: list[str] | tuple[str, ...], env: dict[str, str], cwd: Path) -> str:
    return _receipt_probe(command, env, cwd, timeout=PROBE_TIMEOUT_SECONDS)

SCHEMA = 3
LOCAL_RUNNER_COMMAND = "scripts/run-tests-local.py"
MAX_VERDICT_AGE_SECONDS = 7 * 86400
RUNNER_FILES = ("scripts/run-tests-local.py", "scripts/run-tests.sh",
                "scripts/lib/test-suites.sh", "scripts/lib/bats-jobs.sh",
                "scripts/lib/gate_receipts.py", "scripts/lib/gate_verdict.py",
                "scripts/lib/receipt_provenance.py", "scripts/tests/stage-weights.tsv",
                "scripts/tests/helpers/native-cargo.bash", "scripts/tests/helpers/native-cargo-home.py",
                "native/trellis-hooks/Cargo.lock",
                "scripts/tests/helpers/git-fence/git", "scripts/tests/helpers/git-fence/mktemp")
TOOLS = ("bash", "bats", "jq", "git", "node", "pnpm", "perl", "python3", "python", "shellcheck", "ruff", "mypy", "mktemp",
         "timeout", "gtimeout", "uv", "shfmt", "lsof", "ps", "gh", "npm", "npx",
         "bun", "deno", "yarn", "go", "cargo", "rustc", "make", "java", "ruby",
         "cc", "c++", "ar", "ld", "clang", "gcc", "xcrun")
# BSD utilities lack a portable version interface; JS entrypoints are hashed,
# not invoked; project toolchains without a uniform --version are hashed too.
# Every executable still binds its resolved path and bytes.
BINARY_ONLY_TOOLS = {"mktemp", "lsof", "ps", "npm", "npx", "bun", "deno", "yarn", "go", "cargo", "rustc",
                     "make", "java", "ruby", "cc", "c++", "ar", "ld", "clang", "gcc", "xcrun"}
# The process-gate modules that decide and record a project command verdict.
GATE_MODULES = ("gate_verdict.py", "gate_receipts.py", "receipt_provenance.py")
# Keep these non-recursive globs aligned with scripts/lib/test-suites.sh.
DISCOVERY_GLOBS = ("scripts/tests/*.bats", "core-rules/hooks/tests/*.bats",
                   "core-rules/codex/hooks/tests/*.bats", "core-rules/skills/*/tests/*.bats")
# These values control queueing, output paths, inherited slot ownership or the
# runtime bound, never suite selection/content. TRELLIS_LOCAL_GATE_DEADLINE only
# bounds how long the full battery may run (default 7200 s, cap 14400 s); a run
# cut by it exits 124 and never records a pass. Other TRELLIS_LOCAL_GATE_* values
# are test seams.
OPERATIONAL_ENV = {"_", "SHLVL", "TRELLIS_LOCAL_GATE_RECEIPT", "TRELLIS_LOCAL_GATE_QUEUE_WAIT",
                   "TRELLIS_LOCAL_GATE_DEADLINE",
                   "TRELLIS_HEAVY_FD", "TRELLIS_HEAVY_TOKEN", "TRELLIS_HEAVY_SLOT",
                   "TRELLIS_HEAVY_POOL", "TRELLIS_HEAVY_DIR_ID"}

# The one table of environment names a verdict may not ignore. "refuse": a run
# under the name narrows the suite or injects code, so it neither records nor
# reuses. "key": the value changes what a run does, so it joins the key. A
# trailing "*" is a prefix; the first matching row wins, so exemptions come
# first. Names not listed are not keyed: the managed pre-push dispatcher runs
# the gate under env -i, so only its fixed environment, the committed
# gate.env_passthrough names (always keyed) and DOCKER_HOST reach a managed gate.
ENV_RULES = (
    # Exemptions: transport, paths and output knobs that never select or shape tests.
    *((name, "ignore", "trellis") for name in sorted(OPERATIONAL_ENV)),
    ("TRELLIS_TEST_SHARDS", "ignore", "trellis"),
    ("PYTHONDONTWRITEBYTECODE", "ignore", "python"),
    ("PYTHONUNBUFFERED", "ignore", "python"),
    ("COREPACK_HOME", "ignore", "node"),
    ("TRELLIS_GATE_ENV_POLICY", "ignore", "trellis"),  # keyed as inputs["policy"]
    ("CARGO_TARGET_DIR", "ignore", "cargo"),
    ("CARGO_TERM_*", "ignore", "cargo"),
    # Build parallelism changes how fast, never what is built or run (the
    # t45 qualification run and the release runbook export it).
    ("CARGO_BUILD_JOBS", "ignore", "cargo"),
    # Test-thread counts change scheduling, which a racy suite can observe:
    # keyed, not refused.
    ("RUST_TEST_THREADS", "key", "cargo"),
    ("NEXTEST_TEST_THREADS", "key", "cargo"),
    # Offline only blocks network fetches (the qualification runbook sets it);
    # a locked, vendored build is the same either way, but keep the value.
    ("CARGO_NET_OFFLINE", "key", "cargo"),
    # Trellis and Bats selection and test seams.
    ("PG_PUSH_TEST_SCOPE", "refuse", "trellis"),
    ("BATS_TEST_FILTER", "refuse", "bats"),
    ("BATS_FILTER", "refuse", "bats"),
    ("AGGREGATE_SCRIPT", "refuse", "trellis"),
    ("PACKER", "refuse", "trellis"),
    ("TRELLIS_A1_TEST_BIN", "refuse", "trellis"),
    ("TRELLIS_TEST_*", "refuse", "trellis"),
    ("TRELLIS_LOCAL_GATE_*", "refuse", "trellis"),
    ("TRELLIS_HEAVY_TEST*", "refuse", "trellis"),
    # Runner narrowing controls.
    ("PYTEST_*", "refuse", "pytest"),       # PYTEST_ADDOPTS='-k ...', plugins
    ("JEST_*", "refuse", "jest"),
    ("VITEST", "refuse", "vitest"),
    ("VITEST_*", "refuse", "vitest"),
    ("NEXTEST_*", "refuse", "cargo"),       # profiles and filtersets
    ("CARGO_*", "refuse", "cargo"),         # CARGO_BUILD_*, runners, rustflags
    ("RUSTFLAGS", "refuse", "cargo"),
    ("RUSTDOCFLAGS", "refuse", "cargo"),
    ("RUSTC*", "refuse", "cargo"),          # RUSTC, RUSTC_WRAPPER
    ("RUST_*", "refuse", "cargo"),          # e.g. RUST_MIN_STACK
    ("CC", "refuse", "cargo"),
    ("CC_*", "refuse", "cargo"),
    ("CXX", "refuse", "cargo"),
    ("CXX_*", "refuse", "cargo"),
    ("AR", "refuse", "cargo"),
    ("AR_*", "refuse", "cargo"),
    ("CFLAGS", "refuse", "cargo"),
    ("CXXFLAGS", "refuse", "cargo"),
    ("CPPFLAGS", "refuse", "cargo"),
    ("LDFLAGS", "refuse", "cargo"),
    ("SDKROOT", "key", "cargo"),
    ("DEVELOPER_DIR", "key", "cargo"),
    ("MACOSX_DEPLOYMENT_TARGET", "key", "cargo"),
    ("GOFLAGS", "refuse", "go"),            # GOFLAGS=-run=...
    ("GOROOT", "refuse", "go"),             # another toolchain's tools and std
    ("GOWORK", "refuse", "go"),             # a workspace outside the tree (GOWORK=off is keyed)
    ("GOENV", "refuse", "go"),              # a go env file can set GOFLAGS
    ("MAKEFLAGS", "refuse", "make"),        # -k, variable overrides
    ("GNUMAKEFLAGS", "refuse", "make"),
    ("MFLAGS", "refuse", "make"),
    ("MAKEFILES", "refuse", "make"),        # extra makefiles read first
    # Code injection and interpreter search paths.
    ("LD_*", "refuse", "loader"),
    ("DYLD_*", "refuse", "loader"),
    ("BASH_ENV", "refuse", "shell"),
    ("ENV", "refuse", "shell"),
    ("SHELLOPTS", "refuse", "shell"),
    ("BASHOPTS", "refuse", "shell"),
    # Exported functions and CDPATH are common in ordinary shells (bats,
    # RHEL's which, module systems): keyed below, never refused.
    ("IFS", "refuse", "shell"),
    ("POSIXLY_CORRECT", "refuse", "shell"),
    ("PYTHON*", "refuse", "python"),        # PYTHONPATH, PYTHONSTARTUP, PYTHONHASHSEED
    ("PERL*", "refuse", "perl"),
    ("RUBY*", "refuse", "ruby"),
    ("GEM_*", "refuse", "ruby"),
    ("BUNDLE_*", "refuse", "ruby"),
    ("NODE_ENV", "key", "node"),
    ("NODE_EXTRA_CA_CERTS", "key", "node"),  # corporate CA bundles; TLS only
    ("NODE_*", "refuse", "node"),           # NODE_OPTIONS, NODE_PATH
    ("npm_config_*", "refuse", "node"),
    ("NPM_CONFIG_*", "refuse", "node"),
    # Trellis sets this for prior hooks (attachment.sh): stricter installs, never selection.
    ("pnpm_config_verify_deps_before_run", "key", "node"),
    ("pnpm_config_*", "refuse", "node"),
    ("PNPM_CONFIG_*", "refuse", "node"),
    ("JAVA_TOOL_OPTIONS", "refuse", "java"),
    ("JDK_JAVA_OPTIONS", "refuse", "java"),
    ("_JAVA_OPTIONS", "refuse", "java"),
    ("JAVA_OPTS", "refuse", "java"),
    ("CLASSPATH", "refuse", "java"),
    ("MAVEN_OPTS", "refuse", "java"),
    ("MAVEN_ARGS", "refuse", "java"),
    ("GRADLE_OPTS", "refuse", "java"),
    # Values that change what an unchanged suite does.
    ("BASH_FUNC_*", "key", "shell"),
    ("CDPATH", "key", "shell"),
    ("CI", "key", "jest"),                  # --ci: snapshots are not written
    ("TZ", "key", "any"),
    ("LANG", "key", "any"),
    ("LANGUAGE", "key", "any"),
    ("LC_*", "key", "any"),
    ("COREPACK_*", "key", "node"),
    ("DOCKER_CONFIG", "refuse", "docker"),  # redirects contexts and CLI config
    ("DOCKER_*", "key", "docker"),
    ("GOTOOLCHAIN", "key", "go"),
    ("GOEXPERIMENT", "key", "go"),
    ("GODEBUG", "key", "go"),
    ("GOOS", "key", "go"),
    ("GOARCH", "key", "go"),
    ("CGO_ENABLED", "key", "go"),
    # Keyed by value, except a path-valued one (see PATH_VALUED_FAMILIES).
    ("UV_*", "key", "python"),
    ("PDM_*", "key", "python"),
    ("YARN_*", "key", "node"),
)
# A path-valued setting in these families names a config file, project,
# interpreter or environment outside the key (UV_CONFIG_FILE, PDM_CONFIG_FILE,
# YARN_RC_FILENAME, UV_PYTHON=/opt/...): keying its value binds the name, not
# what it points at, so it refuses (r151 reuse4). URLs and scalars stay keyed.
PATH_VALUED_FAMILIES = ("UV_", "PDM_", "YARN_")
PATH_VALUED_SUFFIXES = ("_FILE", "_FILENAME", "_PATH", "_DIR", "_HOME", "_ENVIRONMENT", "_PROJECT",
                        "_DIRECTORY", "_FOLDER", "_PYTHON", "_RC")

# The reusable command grammar is an allowlist (r151 L4). A project command is
# reusable only when it parses completely to known test runners started with
# the audited options below; anything else, including any token or form this
# grammar does not know, refuses reuse, and the command then runs in full.
# Simple commands join only with "&&". Each is an optional run of inline
# NAME=value assignments whose names ENV_RULES keys or ignores, optionally after
# a bare `env`, then one of:
#   pytest | py.test | python[3[.N]] [-B|-I|-u]... -m pytest | uv run <those> | pdm run <those>
#   jest | vitest run | vitest --run | node ... --test ...
#   cargo test [-- harness options] | cargo nextest run | go test
#   npm|pnpm|yarn [-s|--silent] test|t|run <script> [-- args]: the committed root
#     package.json script, parsed by this grammar with the args appended. A
#     pre/post script for it refuses, as do workspace, directory and config options.
# Option values must match the row's pattern; positionals only where a row
# names them (tracked directories, or Go package patterns under tracked dirs).
_PATH = r"[A-Za-z0-9_./@+:-]+"
_WORD = r"[A-Za-z0-9_./@+:,-]+"
_FEATURES = r"[A-Za-z0-9_./,:-]+"
_COUNT = r"[0-9]+"
_WORKERS = r"[0-9]+%?"
_GO_DURATION = r"(?:[0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h))+|0"
_CARGO_FLAGS = {"--workspace", "--all", "--all-features", "--no-default-features", "--locked", "--frozen",
                "--offline", "--release", "-q", "--quiet", "-v", "--verbose", "-vv", "--all-targets",
                "--no-fail-fast"}
_CARGO_VALUES = {"--features": _FEATURES, "-F": _FEATURES, "-j": _COUNT, "--jobs": _COUNT,
                 "--color": "auto|always|never", "--target-dir": _PATH}
_NEXTEST_OUTPUT = "immediate|final|immediate-final|never"
_NEXTEST_LEVEL = "none|fail|retry|slow|leak|pass|skip|all"


class Reporter:
    """A reporter option value (r151 F6): a built-in name, or a "./" module
    file tracked in HEAD. A bare specifier resolves as a package from
    node_modules; that, or a path outside the tree, is code the key does not
    bind, and a reporter module can end the run before any test executes."""

    def __init__(self, *builtins: str, multiple: bool = False) -> None:
        self.builtins = frozenset(builtins)
        self.multiple = multiple

    def check(self, root: Path, value: str) -> None:
        for name in value.split(",") if self.multiple else [value]:
            if name in self.builtins:
                continue
            if not name.startswith("./") or not re.fullmatch(_PATH, name) or ".." in name.split("/"):
                raise ValueError("reporter outside the tree: " + name)
            path = name[2:]
            if not git(root, "ls-tree", "HEAD", "--", path).startswith((b"100644 blob ", b"100755 blob ")):
                raise ValueError("reporter is not a tracked file: " + name)


_JEST_REPORTERS = Reporter("default", "summary", "github-actions")
_COVERAGE_REPORTERS = Reporter("clover", "cobertura", "html", "html-spa", "json", "json-summary", "lcov",
                               "lcovonly", "none", "teamcity", "text", "text-lcov", "text-summary", multiple=True)
_VITEST_REPORTERS = Reporter("default", "basic", "verbose", "dot", "json", "junit", "tap", "tap-flat",
                             "hanging-process", "github-actions", "blob", "html", "tree")
_NODE_REPORTERS = Reporter("spec", "tap", "dot", "junit", "lcov")
RUNNER_SPECS: dict[str, dict[str, Any]] = {
    "pytest": {
        "flags": {"-q", "--quiet", "-qq", "-v", "--verbose", "-vv", "-vvv", "-s", "-x", "--exitfirst", "-l",
                  "--showlocals", "--strict-markers", "--strict-config", "--no-header", "--no-summary",
                  "--disable-warnings", "--disable-pytest-warnings", "--full-trace", "--cov", "--no-cov",
                  "--cov-branch"},
        "values": {"--tb": "auto|long|short|line|native|no", "--color": "yes|no|auto", "--code-highlight": "yes|no",
                   "--capture": "fd|sys|no|tee-sys", "--durations": _COUNT, "--durations-min": r"[0-9.]+",
                   "--maxfail": _COUNT, "-n": r"[0-9]+|auto|logical", "--numprocesses": r"[0-9]+|auto|logical",
                   "--dist": "load|loadscope|loadfile|loadgroup|worksteal|no",
                   "--import-mode": "prepend|append|importlib", "--junitxml": _PATH, "--junit-xml": _PATH,
                   "--cov": _WORD, "--cov-report": r"(?:term|term-missing|html|xml|json|lcov|annotate)(?::" + _PATH + ")?",
                   "--cov-fail-under": r"[0-9]+(?:\.[0-9]+)?", "--timeout": _COUNT, "--basetemp": _PATH,
                   "-p": "no:cacheprovider", "-r": "[fEsxXpPaAwN]+"},
        "attached": {"-n", "-r", "-p"},
        "positional": "directory",
    },
    "jest": {
        "flags": {"--ci", "--silent", "--verbose", "--coverage", "--runInBand", "-i", "--detectOpenHandles",
                  "--forceExit", "--logHeapUsage", "--colors", "--passWithNoTests", "--bail", "--json",
                  "--watchAll=false", "--no-cache"},
        "values": {"--maxWorkers": _WORKERS, "-w": _WORKERS, "--testTimeout": _COUNT, "--reporters": _JEST_REPORTERS,
                   "--outputFile": _PATH, "--coverageReporters": _COVERAGE_REPORTERS, "--coverageDirectory": _PATH},
    },
    "vitest": {
        "flags": {"--run", "--coverage", "--silent", "--passWithNoTests", "--no-file-parallelism", "--no-color"},
        "values": {"--reporter": _VITEST_REPORTERS, "--pool": "threads|forks|vmThreads|vmForks", "--maxWorkers": _WORKERS,
                   "--minWorkers": _WORKERS, "--testTimeout": _COUNT, "--outputFile": _PATH, "--bail": _COUNT},
    },
    "node-test": {
        "flags": {"--test", "--experimental-test-coverage", "--test-force-exit", "--enable-source-maps",
                  "--no-warnings"},
        "values": {"--test-reporter": _NODE_REPORTERS, "--test-reporter-destination": _PATH, "--test-concurrency": _COUNT,
                   "--test-timeout": _COUNT, "--test-isolation": "process"},
    },
    "cargo": {"flags": _CARGO_FLAGS, "values": _CARGO_VALUES, "harness": "cargo-harness"},
    "cargo-harness": {
        "flags": {"--nocapture", "--no-capture", "--show-output", "-q", "--quiet"},
        "values": {"--test-threads": _COUNT, "--color": "auto|always|never", "--format": "pretty|terse"},
    },
    "nextest": {
        "flags": {"--workspace", "--all-features", "--no-default-features", "--locked", "--frozen", "--offline",
                  "--release", "--no-fail-fast", "--no-capture", "--nocapture", "--cargo-quiet"},
        "values": {**_CARGO_VALUES, "--test-threads": r"[0-9]+|num-cpus", "--failure-output": _NEXTEST_OUTPUT,
                   "--success-output": _NEXTEST_OUTPUT, "--status-level": _NEXTEST_LEVEL,
                   "--final-status-level": _NEXTEST_LEVEL},
    },
    "go": {
        "flags": {"-v", "-race", "-cover", "-failfast", "-json"},
        "values": {"-count": _COUNT, "-coverprofile": _PATH, "-covermode": "set|count|atomic",
                   "-coverpkg": r"[A-Za-z0-9_./,-]+", "-timeout": _GO_DURATION, "-p": _COUNT, "-parallel": _COUNT,
                   "-tags": r"[A-Za-z0-9_.,-]+", "-mod": "readonly|mod|vendor", "-shuffle": r"on|off|[0-9]+"},
        "positional": "go-package",
    },
}
# The runner whose discovery and configuration a spec runs.
SPEC_RUNNER = {"nextest": "cargo", "cargo-harness": "cargo"}
PACKAGE_MANAGERS = {"npm", "pnpm", "yarn"}
PACKAGE_QUIET = {"-s", "--silent"}
PYTHON_LAUNCHER = re.compile(r"python(?:3(?:\.[0-9]+)?)?")
# Ignored paths are refused unless every runner of the command skips them by
# default (r151 N5: no blanket output-directory allowances). A committed
# discovery setting, or a committed runner config that names the skipped
# directory, refuses them again.
# No directory is exempt for every runner (r151 F8): node --test discovers
# tests inside __pycache__, and go ./... reads any directory not starting with
# "." or "_". A Finder metadata file is no runner's test source.
CACHE_FILES = frozenset({".DS_Store"})
PYTEST_NORECURSE = ("*.egg", ".*", "_darcs", "build", "CVS", "dist", "node_modules", "venv", "{arch}")
RUNNER_SKIPPED = {
    # pytest always skips __pycache__, whatever norecursedirs says.
    "pytest": lambda part: part == "__pycache__" or any(fnmatch.fnmatchcase(part, pattern) for pattern in PYTEST_NORECURSE),
    "jest": lambda part: part == "node_modules",
    "vitest": lambda part: part == "node_modules",
    "node-test": lambda part: part == "node_modules",
    "cargo": lambda part: part == "target",
    "go": lambda part: part[:1] in (".", "_"),  # ./... skips them; testdata and vendor are inputs
}
PYTEST_CONFIGS = ("pytest.ini", ".pytest.ini", "pyproject.toml", "tox.ini", "setup.cfg")
PYTEST_DISCOVERY_KEYS = ("norecursedirs", "testpaths", "rootdir", "confcutdir")
RUNNER_CONFIGS = {
    "jest": ("jest.config.js", "jest.config.ts", "jest.config.mjs", "jest.config.cjs", "jest.config.json",
             "package.json"),
    "vitest": ("vitest.config.ts", "vitest.config.js", "vitest.config.mts", "vitest.config.mjs",
               "vite.config.ts", "vite.config.js", "vite.config.mts", "vite.config.mjs", "vitest.workspace.ts",
               "vitest.workspace.js", "package.json"),
    "go": ("go.mod", "go.work"),
}


def encoded(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def key(inputs: dict[str, Any]) -> str:
    return digest(encoded(inputs))


def git(root: Path, *args: str) -> bytes:
    env = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    return subprocess.check_output(["git", "-C", str(root), *args], env=env, stderr=subprocess.DEVNULL, timeout=5)


class ProbeUnavailable(ValueError):
    """A toolchain probe gave no answer (timeout, exit, no output).

    It costs reuse only. When everything else about the command was reusable,
    capture_inputs attaches `scope` (schema, tree, command), so the lookup can
    still track the run and a failure still supersedes passes for them.
    """

    scope: dict[str, Any] | None = None


def native_decision(root: Path) -> str:
    """The full battery's native-stage decision (run|skip), as run-tests.sh makes it.

    run-tests.sh registers the cargo stages only when the diff from the
    resolved base touches a native build input. The base comes from refs and
    branch config, which are not keyed, so the same tree can skip them in one
    range and need them in another: the decision itself is keyed (r151
    cargo-fence (a)). run-tests-local passes no base, --quick or selection, so
    only TRELLIS_SLOW_TESTS=1 overrides it. Anything unreadable refuses.
    """
    if os.environ.get("TRELLIS_SLOW_TESTS") == "1":
        return "run"
    env = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    result = subprocess.run(["bash", "-c", '. "$1" && test_suites_native_decision local', "_",
                             str(root / "scripts/lib/test-suites.sh")], cwd=root, env=env,
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=20, check=False)
    decision = result.stdout.decode("utf-8", "replace").partition("\t")[0]
    if result.returncode != 0 or decision not in ("run", "skip"):
        raise ValueError("native-stage decision unreadable")
    return decision


def ref_rows(root: Path) -> list[str] | None:
    """Every ref and its object. Not keyed: evidence for release-metadata
    narrowing, which must see tags and other branches unchanged since the base."""
    try:
        return git(root, "for-each-ref", "--format=%(refname) %(objectname)").decode().splitlines()
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def toolchain(root: Path, version_probe=probe) -> dict[str, Any]:
    # Version probes are identity reads: they must not write the caller's state
    # (gh --version creates $XDG_STATE_HOME/gh/device-id) or download a tool.
    with tempfile.TemporaryDirectory(prefix="gate-verdict-probe.") as scratch:
        env = os.environ | {"COREPACK_ENABLE_NETWORK": "0", "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0",
                            "RUSTUP_AUTO_INSTALL": "0",
                            "XDG_STATE_HOME": scratch + "/state", "XDG_CACHE_HOME": scratch + "/cache"}
        return _toolchain(root, version_probe, env)


# Version-manager shims: <root>/shims/<tool> dispatches through `<manager> which`.
SHIM_MANAGERS = {".pyenv": ("pyenv", "PYENV_ROOT"), ".rbenv": ("rbenv", "RBENV_ROOT"),
                 ".nodenv": ("nodenv", "NODENV_ROOT"), ".goenv": ("goenv", "GOENV_ROOT"),
                 ".jenv": ("jenv", "JENV_ROOT"), ".asdf": ("asdf", "ASDF_DATA_DIR"),
                 "asdf": ("asdf", "ASDF_DATA_DIR"), "mise": ("mise", "MISE_DATA_DIR")}
# Multi-call binaries that pick the real tool from argv[0] and project files.
# rustup-init is the installer under another name: never run it, refuse.
DISPATCHER_BINARIES = {"rustup": "rustup", "rustup-init": None, "mise": "mise", "volta-shim": "volta"}
# Names a rustup proxy answers to. A proxy is recognised by what the
# executable is, not by what its path resolves to (r151 N6: a hard link keeps
# its own name): rustup obeys RUSTUP_FORCE_ARG0, a real compiler ignores it.
RUSTUP_PROXIES = {"cargo", "rustc", "rustdoc", "rustfmt", "cargo-fmt", "cargo-clippy", "clippy-driver",
                  "rust-analyzer", "rust-gdb", "rust-lldb", "rls", "cargo-miri"}


# Both run through the caller's version probe (r151 cargo-fence (b)), so
# run-tests-local contains them like every other probe: a registered group,
# bounded, and swept before the verified-empty scan. A probe answers with its
# first output line or "unavailable: ...".
def _is_rustup(path: Path, root: Path, env: dict[str, str], version_probe=probe) -> bool:
    # Only an answer means "not rustup" (r151-reuse4 R3): a detection that
    # timed out or said nothing leaves the compiler unbound, so it costs reuse.
    answer = version_probe([str(path), "--version"], env | {"RUSTUP_FORCE_ARG0": "rustup"}, root).strip()
    if not answer or answer.startswith("unavailable:"):
        raise ProbeUnavailable("rustup detection probe failed: " + str(path))
    return answer.startswith("rustup ")


def _dispatch_output(argv: list[str], root: Path, env: dict[str, str], version_probe=probe) -> str:
    text = version_probe(argv, env, root).strip()
    if not text or text.startswith("unavailable:"):
        raise ProbeUnavailable("toolchain dispatcher could not name the tool: " + " ".join(argv[1:]))
    return text


def effective_tool(name: str, found: Path, path: Path, root: Path, env: dict[str, str],
                   version_probe=probe) -> dict[str, Any] | None:
    """Bind the tool a version manager actually runs, not its shim or proxy.

    rustup, mise and volta proxies are one binary for every toolchain, and an
    *env/asdf shim is one script; the toolchain they select comes from the
    environment and project files. Any doubt raises: reuse is then refused.
    nvm switches PATH itself, so its node is already the resolved binary.
    """
    if path.name != name and path.name in DISPATCHER_BINARIES and DISPATCHER_BINARIES[path.name] is None:
        raise ValueError("unsupported toolchain dispatcher: " + str(path))
    manager = DISPATCHER_BINARIES.get(path.name) if path.name != name else None
    if manager is None and name in RUSTUP_PROXIES and found.parent.name != "shims" and _is_rustup(path, root, env, version_probe):
        manager = "rustup"
    manager_env = dict(env)
    if manager == "rustup":
        manager_env["RUSTUP_FORCE_ARG0"] = "rustup"
    executable = str(path)
    if manager is None and found.parent.name == "shims":
        known = SHIM_MANAGERS.get(found.parent.parent.name)
        if known is None:
            raise ValueError("unknown version-manager shim: " + str(found))
        manager, root_variable = known
        manager_env[root_variable] = str(found.parent.parent)
        located = shutil.which(manager)
        for candidate in (found.parent.parent / "bin" / manager, found.parent.parent / "libexec" / manager):
            if located is None and candidate.is_file():
                located = str(candidate)
        if located is None:
            raise ValueError("version manager not found: " + manager)
        executable = located
    elif manager is not None and manager != "rustup":
        located = shutil.which(manager)
        if located is None:
            raise ValueError("version manager not found: " + manager)
        executable = located
    if manager is None:
        return None
    identity: dict[str, Any] = {"manager": manager}
    if manager == "rustup":
        rustup_home = Path(env.get("RUSTUP_HOME") or env.get("HOME", "") + "/.rustup")
        toolchains = rustup_home / "toolchains"
        if not toolchains.is_dir() or not any(toolchains.iterdir()):
            # No toolchain is installed for this environment: the proxy can
            # only fail (auto-install is disabled for the probe), which is an
            # established identity, and an install changes it.
            identity["active"] = None
            identity["rustup_home"] = str(rustup_home)
            return identity
        identity["active"] = _dispatch_output([executable, "show", "active-toolchain"], root, manager_env, version_probe)
    selected = Path(_dispatch_output([executable, "which", name], root, manager_env, version_probe)).resolve(strict=True)
    identity["path"] = str(selected)
    identity["binary"] = digest(selected.read_bytes())
    return identity


def _toolchain(root: Path, version_probe, env: dict[str, str]) -> dict[str, Any]:
    tools: dict[str, Any] = {}
    for name in TOOLS:
        executable = shutil.which(name)
        if executable:
            path = Path(executable).resolve(strict=True)
            entry: dict[str, Any] = {"path": str(path), "binary": digest(path.read_bytes())}
            effective = effective_tool(name, Path(executable), path, root, env, version_probe)
            if effective is not None:
                entry["effective"] = effective
            if name in BINARY_ONLY_TOOLS:
                entry["binding"] = "binary-only"
                package = path.parent.parent / "package.json"
                if name in ("npm", "npx") and path.parent.name == "bin" and package.is_file():
                    entry["package"] = digest(package.read_bytes())
            else:
                # Probe through the name PATH found, so a multi-call binary
                # reports the tool it dispatches to, not itself.
                version = version_probe([executable, "--version"], env, root)
                if not version or version.startswith("unavailable:"):
                    raise ProbeUnavailable("tool version probe failed: " + name)
                entry["version"] = version
            tools[name] = entry
        else:
            tools[name] = {"unavailable": True}
    tools["interpreter"] = {"path": sys.executable, "version": sys.version,
                            "binary": digest(Path(sys.executable).read_bytes())}
    return tools


def toolchain_unchanged(tools: dict[str, Any]) -> bool:
    """Re-hash the executables a captured toolchain names, without probing versions."""
    try:
        for name in TOOLS:
            entry = tools[name]
            executable = shutil.which(name)
            if entry.get("unavailable") is True:
                if executable:
                    return False
                continue
            if not executable or str(Path(executable).resolve(strict=True)) != entry["path"]:
                return False
            if digest(Path(entry["path"]).read_bytes()) != entry["binary"]:
                return False
            effective = entry.get("effective")
            if effective and "path" in effective and digest(Path(effective["path"]).read_bytes()) != effective["binary"]:
                return False
        interpreter = tools["interpreter"]
        return interpreter["path"] == sys.executable and digest(Path(sys.executable).read_bytes()) == interpreter["binary"]
    except (OSError, KeyError, TypeError, AttributeError):
        return False


def project_gate_policy(root: Path) -> tuple[bool, list[str]]:
    """(reuse allowed, env_passthrough names) from the committed .trellis.json gate block.

    gate.verdict_reuse=false opts out (tests read external state). An
    unreadable or mistyped policy never widens reuse.
    """
    try:
        blob = git(root, "cat-file", "blob", "HEAD:.trellis.json")
    except subprocess.CalledProcessError:
        return True, []  # No committed project policy: reuse is the default.
    try:
        document = json.loads(blob.decode("utf-8"))
    except (UnicodeError, ValueError):
        return False, []
    if not isinstance(document, dict):
        return False, []
    gate = document.get("gate", {})
    if not isinstance(gate, dict):
        return False, []
    names = gate.get("env_passthrough", [])
    if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
        return False, []
    return gate.get("verdict_reuse", True) is True, sorted(set(names))


def reuse_opted_out(root: Path) -> bool:
    return not project_gate_policy(root)[0]


def env_rule(name: str, value: str | None = None) -> tuple[str, str] | None:
    """(action, owner) of the first ENV_RULES row naming `name`; a path-valued
    `value` in PATH_VALUED_FAMILIES refuses."""
    for pattern, action, owner in ENV_RULES:
        if name == pattern or pattern.endswith("*") and name.startswith(pattern[:-1]):
            if action == "key" and _path_valued(name, value):
                return "refuse", owner
            if name == "GOWORK" and value == "off":
                return "key", owner
            return action, owner
    return None


def _path_valued(name: str, value: str | None) -> bool:
    if not name.startswith(PATH_VALUED_FAMILIES):
        return False
    if name.endswith(PATH_VALUED_SUFFIXES):
        return True
    # Only an http(s) URL is not a path; file: and every other scheme name local resources.
    return value is not None and ("/" in value or value.startswith("~") or value.lower().startswith("file:")) \
        and not re.match(r"https?://", value, re.IGNORECASE)


def keyed_environment(passthrough: list[str], environ: dict[str, str] | None = None) -> dict[str, str | None]:
    """Values that join the key; a refused name raises instead."""
    environ = dict(os.environ) if environ is None else environ
    keyed: dict[str, str | None] = {}
    for name in sorted(environ):
        rule = env_rule(name, environ[name])
        if rule is not None and rule[0] == "refuse":
            raise ValueError("narrowed, test-seam or injected environment: " + name)
        if rule is not None and rule[0] == "key":
            keyed[name] = environ[name]
    for name in passthrough:  # Committed passthrough values reach the tests: key them, set or not.
        keyed[name] = environ.get(name)
    return keyed


CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def _simple_commands(command: str) -> list[list[str]]:
    """Words of each "&&"-joined simple command; any other operator or shell
    expansion refuses. Raw tokens keep their quotes, so a quoted "&&" is a word.
    A control character refuses: shlex reads a newline as whitespace where
    the shell reads a command separator (r151 F2)."""
    if CONTROL.search(command):
        raise ValueError("control character in the command")
    lexer = shlex.shlex(command, posix=False, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    commands: list[list[str]] = [[]]
    for raw in lexer:
        if raw and set(raw) <= set(";&|()<>"):
            if raw != "&&":
                raise ValueError("shell operator " + raw)
            commands.append([])
            continue
        if any(c in raw for c in "$`*?[]{}~\\!#"):
            raise ValueError("shell expansion in " + raw)
        words = shlex.split(raw)
        if len(words) != 1:
            raise ValueError("unparseable word " + raw)
        commands[-1].append(words[0])
    if any(not words for words in commands):
        raise ValueError("empty simple command")
    return commands


def _canonical(path: str) -> str:
    """One spelling per directory: `./.hidden`, `.hidden/` and `.hidden` are one root."""
    return posixpath.normpath(path) if path else "."


def _tracked_directory(root: Path, path: str) -> None:
    if path.startswith(("/", "-")) or ".." in path.split("/"):
        raise ValueError("positional outside the checkout: " + path)
    path = _canonical(path)
    if path != "." and not git(root, "ls-tree", "-d", "HEAD", "--", path).startswith(b"040000 tree "):
        raise ValueError("positional is not a tracked directory: " + path)


def _audited_args(root: Path, spec_name: str, args: list[str]) -> list[str]:
    """Audit a runner's argv; return the tracked directories it names as roots."""
    spec = RUNNER_SPECS[spec_name]
    roots: list[str] = []
    index = 0
    while index < len(args):
        arg = args[index]
        index += 1
        if arg == "--" and "harness" in spec:
            _audited_args(root, spec["harness"], args[index:])
            return roots
        if arg in spec["flags"]:
            continue
        name, separator, value = arg.partition("=")
        if name not in spec["values"] and arg[:2] in spec.get("attached", ()) and len(arg) > 2:
            name, separator, value = arg[:2], "=", arg[2:]
        pattern = spec["values"].get(name)
        if pattern is not None:
            if not separator:
                if index >= len(args):
                    raise ValueError("{} option without its value: {}".format(spec_name, arg))
                value = args[index]
                index += 1
            if isinstance(pattern, Reporter):
                pattern.check(root, value)
            elif not re.fullmatch(pattern, value):
                raise ValueError("{} option value the reuse grammar does not know: {}".format(spec_name, arg))
            continue
        if not arg.startswith("-") and spec.get("positional") == "directory":
            _tracked_directory(root, arg)
            roots.append(_canonical(arg))
            continue
        if not arg.startswith("-") and spec.get("positional") == "go-package":
            directory = arg[:-len("/...")] if arg.endswith("/...") else arg
            parts = directory.split("/")
            if parts[0] != "." or not all(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", part) for part in parts[1:]):
                raise ValueError("go package pattern the reuse grammar does not know: " + arg)
            _tracked_directory(root, "/".join(parts[1:]) or ".")
            roots.append(_canonical("/".join(parts[1:])))
            continue
        raise ValueError("{} option the reuse grammar does not know: {}".format(spec_name, arg))
    return roots


def _runner_form(words: list[str]) -> tuple[str, list[str], list[str]]:
    """(spec, its argv, wrappers) of a test-runner invocation, or raise."""
    program = words[0]
    if program in ("uv", "pdm"):
        if words[1:2] != ["run"] or len(words) < 3 or words[2].startswith("-"):
            raise ValueError(program + " form the reuse grammar does not know")
        spec, args, wrappers = _runner_form(words[2:])
        if spec != "pytest":
            raise ValueError(program + " run supports only pytest")
        return spec, args, [program, *wrappers]
    if program in ("pytest", "py.test"):
        return "pytest", words[1:], []
    if PYTHON_LAUNCHER.fullmatch(program):
        index = 1
        while index < len(words) and words[index] in ("-B", "-I", "-u"):
            index += 1
        if words[index:index + 2] == ["-m", "pytest"]:
            return "pytest", words[index + 2:], [program]
        raise ValueError("python form the reuse grammar does not know")
    if program == "jest":
        return "jest", words[1:], []
    if program == "vitest":
        if words[1:2] == ["run"]:
            return "vitest", words[2:], []
        if "--run" in words[1:]:
            return "vitest", words[1:], []
        raise ValueError("vitest without run is watch mode")
    if program == "node" and "--test" in words[1:]:
        return "node-test", words[1:], []
    if program == "cargo":
        index = 1
        while index < len(words) and words[index] in _CARGO_FLAGS:
            index += 1
        if words[index:index + 1] == ["test"]:
            return "cargo", words[1:index] + words[index + 1:], []
        if words[index:index + 2] == ["nextest", "run"]:
            return "nextest", words[1:index] + words[index + 2:], []
        raise ValueError("cargo form the reuse grammar does not know")
    if program == "go" and words[1:2] == ["test"]:
        return "go", words[2:], []
    raise ValueError("not a known test runner: " + program)


def _package_script(root: Path, words: list[str]) -> str:
    """The committed root package.json script that `npm test` / `pnpm run x` runs."""
    manager, index = words[0], 1
    while index < len(words) and words[index] in PACKAGE_QUIET:
        index += 1
    verb = words[index] if index < len(words) else ""
    if verb in ("test", "t") or manager == "npm" and verb == "tst":
        name, index = "test", index + 1
    elif verb == "run" or manager != "yarn" and verb == "run-script":
        if index + 1 >= len(words) or words[index + 1].startswith("-"):
            raise ValueError(manager + " run without a script name")
        name, index = words[index + 1], index + 2
    else:
        raise ValueError(manager + " form the reuse grammar does not know: " + verb)
    rest = words[index:]
    if rest and (rest[0] != "--" or manager == "yarn"):
        raise ValueError(manager + " option or argument the reuse grammar does not know: " + rest[0])
    try:
        document = json.loads(git(root, "cat-file", "blob", "HEAD:package.json").decode("utf-8"))
        scripts = document["scripts"]
        script = scripts[name]
    except (subprocess.CalledProcessError, UnicodeError, ValueError, KeyError, TypeError) as error:
        raise ValueError("no committed package.json script " + name) from error
    if not isinstance(script, str) or not isinstance(scripts, dict):
        raise ValueError("package.json script is not a string: " + name)
    if CONTROL.search(script) or any(CONTROL.search(word) for word in rest):
        raise ValueError("control character in package.json script " + name)
    if "pre" + name in scripts or "post" + name in scripts:
        raise ValueError("package.json has a pre/post script for " + name)
    extra = rest[1:]
    return script + (" " + shlex.join(extra) if extra else "")


def command_runners(root: Path, command: str, depth: int = 0) -> tuple[list[str], list[str], list[tuple[str, str]]]:
    """(runners, wrappers, (runner, root) pairs) of a reusable command; raise
    if any part is not. A runner given no directory has the root "."."""
    if depth > 3:
        raise ValueError("package scripts nest too deeply")
    runners: list[str] = []
    wrappers: list[str] = []
    roots: list[tuple[str, str]] = []
    for words in _simple_commands(command):
        index = 0
        for prefix_env in (False, True):
            if prefix_env and words[index:index + 1] == ["env"]:
                index += 1
            while index < len(words) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[index]):
                rule = env_rule(*words[index].split("=", 1))
                if rule is None or rule[0] not in ("key", "ignore"):
                    raise ValueError("inline assignment the reuse grammar does not know: " + words[index])
                index += 1
        program = words[index:]
        if not program:
            raise ValueError("assignments without a command")
        if "/" in program[0]:
            raise ValueError("path-qualified program: " + program[0])
        if program[0] in PACKAGE_MANAGERS:
            nested_runners, nested_wrappers, nested_roots = command_runners(root, _package_script(root, program), depth + 1)
            runners.extend(nested_runners)
            wrappers.extend([program[0], *nested_wrappers])
            roots.extend(nested_roots)
            continue
        spec, args, form_wrappers = _runner_form(program)
        runner = SPEC_RUNNER.get(spec, spec)
        roots.extend((runner, directory) for directory in (_audited_args(root, spec, args) or ["."]))
        runners.append(runner)
        wrappers.extend(form_wrappers)
    return runners, wrappers, roots


def _committed_text(root: Path, name: str) -> str | None:
    try:
        return git(root, "cat-file", "blob", "HEAD:" + name).decode("utf-8", "replace")
    except subprocess.CalledProcessError:
        return None


def _runner_config_texts(root: Path, runner: str) -> list[str]:
    """The committed configuration a runner reads for its discovery."""
    if runner == "pytest":
        texts = []
        for name in PYTEST_CONFIGS:
            text = _committed_text(root, name)
            if text is None:
                continue
            if name == "pyproject.toml":
                try:
                    section = tomllib.loads(text).get("tool", {}).get("pytest", {}) if tomllib else {"whole": text}
                except (ValueError, AttributeError):
                    section = {"unparseable": text}
                texts.append(json.dumps(section))
            else:
                parser = configparser.ConfigParser(interpolation=None)
                try:
                    parser.read_string(text)
                except configparser.Error:
                    texts.append(text)
                    continue
                for section in ("pytest", "tool:pytest"):
                    if parser.has_section(section):
                        texts.append(json.dumps(dict(parser.items(section))))
        conftest = _committed_text(root, "conftest.py")
        return texts + ([conftest] if conftest is not None else [])
    if runner == "cargo":
        names = [name for name in git(root, "ls-files", "-z").decode("utf-8", "surrogateescape").split("\0")
                 if name == "Cargo.toml" or name.endswith(("/Cargo.toml", ".cargo/config.toml", ".cargo/config"))]
        return [text for text in (_committed_text(root, name) for name in names) if text is not None]
    return [text for text in (_committed_text(root, name) for name in RUNNER_CONFIGS.get(runner, ())) if text is not None]


# r151-reuse4 R2: a reporter named in committed runner configuration meets
# the same contract as one on the command line (built-in, or a tracked file
# inside the tree). JSON configuration is checked entry by entry; executable
# (JS/TS) configuration that mentions a reporter at all refuses, since its
# value cannot be read without running it. That token check bounds honest
# configuration: committed code that hides a reporter from it can as well
# load outside files from a test, which is the documented same-UID residual.
JEST_CONFIG_REPORTERS = (("reporters", _JEST_REPORTERS), ("coverageReporters", _COVERAGE_REPORTERS),
                         ("testResultsProcessor", Reporter()))
# Other Jest options that load a module. A package name resolves from
# node_modules (the dependency residual); an absolute or outside path is
# code the key does not bind and refuses.
JEST_MODULE_KEYS = ("preset", "globalSetup", "globalTeardown", "setupFiles", "setupFilesAfterEnv", "testEnvironment",
                    "testRunner", "runner", "resolver", "snapshotResolver", "testSequencer", "transform", "watchPlugins",
                    "dependencyExtractor", "prettierPath", "moduleLoader", "rootDir", "roots", "modulePaths",
                    "moduleDirectories", "moduleNameMapper")
EXECUTABLE_REPORTER = re.compile(r"reporter|testResultsProcessor", re.IGNORECASE)
# Every root configuration file name the runners accept, by pattern rather
# than a list that can fall behind (jest.config.cts, vite.config.cjs, ...).
REPORTER_CONFIG_FILES = {"jest": re.compile(r"package\.json|jest\.config\.[A-Za-z]+"),
                         "vitest": re.compile(r"(?:vitest|vite)\.config\.[A-Za-z]+|vitest\.(?:workspace|projects)\.[A-Za-z]+")}


def _module_values(value: Any) -> list[Any]:
    if isinstance(value, dict):
        return [item for entry in value.values() for item in _module_values(entry)]
    if isinstance(value, list):
        if len(value) == 2 and isinstance(value[0], str) and isinstance(value[1], dict):
            return [value[0]]  # [module, options]
        return [item for entry in value for item in _module_values(entry)]
    return [value]


def _contained(root: Path, relative: str) -> bool:
    """Whether root/relative stays inside the real tree root, symlinks followed."""
    real_root = os.path.realpath(root)
    real = os.path.realpath(os.path.join(real_root, relative))
    return real == real_root or real.startswith(real_root + os.sep)


def _outside_module(root: Path, value: Any) -> bool:
    """A Jest path value that leaves the tree, lexically or through a symlink."""
    if not isinstance(value, str):
        return True
    if "<rootDir>" in value:
        if value != "<rootDir>" and not value.startswith("<rootDir>/") or value.count("<rootDir>") > 1:
            return True  # "<rootDir>../x" is a sibling of the tree
        value = "." + value[len("<rootDir>"):]
    if value.startswith(("/", "~", "$")):
        return True
    if posixpath.normpath(value).split("/")[0].lower() in ("..", ".git"):
        return True  # .git holds unkeyed refs, config and hooks
    if not _contained(root, value):
        return True
    real_root = os.path.realpath(root)
    real = os.path.relpath(os.path.realpath(os.path.join(real_root, value)), real_root)
    return real.split(os.sep)[0].lower() == ".git"


def _jest_config_reporter(root: Path, config: dict[str, Any]) -> str | None:
    for field, contract in JEST_CONFIG_REPORTERS:
        value = config.get(field)
        if value is None:
            continue
        for entry in value if isinstance(value, list) else [value]:
            if isinstance(entry, list) and entry:
                entry = entry[0]  # [module, options]
            if not isinstance(entry, str):
                return field
            name = "./" + entry[len("<rootDir>/"):] if entry.startswith("<rootDir>/") else entry
            try:
                contract.check(root, name)
            except ValueError:
                return "{} {}".format(field, entry)
    for field in JEST_MODULE_KEYS:
        if field in config and any(_outside_module(root, item) for item in _module_values(config[field])):
            return field
    projects = config.get("projects") or []
    for project in projects if isinstance(projects, list) else [projects]:
        if not isinstance(project, dict):
            # r151-reuse4 R6: Jest loads a string project's own configuration,
            # which this check never reads; refuse rather than emulate Jest.
            return "projects"
        problem = _jest_config_reporter(root, project)
        if problem is not None:
            return "projects " + problem
    return None


def config_reporter_refusal(root: Path, runners: list[str]) -> str | None:
    """The committed runner configuration naming a reporter outside the tree, if any."""
    names = git(root, "ls-tree", "-z", "--name-only", "HEAD").decode("utf-8", "surrogateescape").split("\0")
    for runner in sorted(set(runners) & {"jest", "vitest"}):
        for name in sorted(name for name in names if REPORTER_CONFIG_FILES[runner].fullmatch(name)):
            text = _committed_text(root, name)
            if text is None:
                continue
            if name.endswith(".json") and runner == "jest":
                try:
                    document = json.loads(text)
                except ValueError:
                    return name + " (unparseable)"
                config = document.get("jest") if name == "package.json" and isinstance(document, dict) else document
                if config is None:
                    continue
                if not isinstance(config, dict):
                    return name + " (jest configuration is not an object)"
                problem = _jest_config_reporter(root, config)
                if problem is not None:
                    return "{} ({})".format(name, problem)
            elif EXECUTABLE_REPORTER.search(text):
                return name + " (reporter in executable configuration)"
    return None


def escaping_symlink(root: Path) -> str | None:
    """A tracked entry whose content the tree key does not bind, if any.

    r151-reuse4 R7: the key binds a symlink's target spelling, not the files
    it reaches. A tracked symlink must therefore resolve, as the kernel
    resolves it in this clean checkout, to a file tracked in HEAD (itself
    keyed). A directory target refuses: ignored files under it would be
    discovered under a name no runner skips. So does an absolute target, one
    outside the real tree root, an untracked or ignored one, or one in .git
    (in any letter case). A gitlink (submodule) refuses too: its content, and
    committed ignore settings for it, are outside this tree.
    """
    entries = [entry for entry in git(root, "ls-tree", "-r", "-z", "HEAD").split(b"\0") if entry]
    files: set[str] = set()
    links: list[tuple[str, str]] = []
    for entry in entries:
        meta, _, name = entry.partition(b"\t")
        path = name.decode("utf-8", "surrogateescape")
        mode, _kind, blob = meta.decode().split()
        if mode == "160000":
            return path + " (submodule)"
        files.add(path)
        if mode == "120000":
            links.append((path, blob))
    real_root = os.path.realpath(root)
    for path, blob in links:
        target = git(root, "cat-file", "blob", blob).decode("utf-8", "surrogateescape")
        real = os.path.realpath(os.path.join(real_root, path))
        relative = os.path.relpath(real, real_root)
        if (target.startswith("/") or not _contained(root, path) or relative not in files
                or relative.split(os.sep)[0].lower() == ".git"):
            return path + " -> " + target
    return None


def _names_directory(texts: list[str], part: str) -> bool:
    pattern = re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(part) + r"(?![A-Za-z0-9_-])")
    return any(pattern.search(text) for text in texts)


def ignored_files_refusal(root: Path, runners: list[str], roots: list[tuple[str, str]] | None = None) -> str | None:
    """A git-ignored path a command's runners might discover, if any.

    An ignored path is safe only where every runner of the command skips it
    by default, when no committed discovery setting, and no committed runner
    config naming that directory, says otherwise; anything else refuses
    reuse. A directory the command names explicitly (`pytest .hidden`,
    `go test ./_tools/...`) is traversed whatever its name, so a path under it
    is judged by its components below that root, and an ignored directory
    holding a root, or a conftest.py on the way to one, refuses (r151 F8).
    """
    roots = roots if roots is not None else [(runner, ".") for runner in runners]
    configs = {runner: _runner_config_texts(root, runner) for runner in set(runners)}
    overridden = {runner for runner, texts in configs.items()
                  if runner == "pytest" and any(re.search(r"\b" + key + r"\b", text)
                                                for key in PYTEST_DISCOVERY_KEYS for text in texts)}
    entries = [entry for entry in git(root, "ls-files", "-z", "-o", "-i", "--directory", "--exclude-standard").split(b"\0")
               if entry]

    def skipped(runner: str, parts: list[str], is_directory: bool) -> bool:
        if runner in overridden:
            return False
        # Directory components; Go also skips a hidden or underscore file.
        candidates = parts if runner == "go" or is_directory else parts[:-1]
        return any(RUNNER_SKIPPED[runner](part) and not _names_directory(configs[runner], part)
                   for part in candidates)

    def safe(runner: str, top: str, parts: list[str], is_directory: bool) -> bool:
        base = [] if top == "." else top.split("/")
        if len(parts) > len(base) and parts[:len(base)] == base:
            return skipped(runner, parts[len(base):], is_directory)
        if is_directory and base[:len(parts)] == parts:
            return False  # The ignored directory holds an explicit root.
        if runner == "pytest" and parts[-1] == "conftest.py" and base[:len(parts) - 1] == parts[:-1]:
            return False  # pytest loads every conftest.py on the way to a root.
        return skipped(runner, parts, is_directory)

    for entry in entries:
        if entry.endswith(b"/") and any(other != entry and other.startswith(entry) for other in entries):
            continue  # Listed with its contents, which are judged one by one.
        is_directory = entry.endswith(b"/")
        parts = entry.decode("utf-8", "surrogateescape").rstrip("/").split("/")
        if parts[-1] in CACHE_FILES and not is_directory:
            continue
        if roots and all(safe(runner, top, parts, is_directory) for runner, top in roots):
            continue
        return entry.decode("utf-8", "replace")
    return None


def _home() -> Path:
    home = os.environ.get("HOME", "")
    if not home.startswith("/"):
        raise ValueError("HOME is not absolute")
    return Path(home)


def _file_identity(path: Path) -> str | None:
    try:
        return digest(path.read_bytes())
    except FileNotFoundError:
        return None
    except NotADirectoryError:
        return None


# Settings in configuration outside the tree that replace the program a test
# run executes, or redirect it to code or configuration the key does not
# bind. Hashing the file binds its text, not the program it names, so a set
# key refuses reuse instead (r151 F1).
CARGO_EXECUTOR_KEYS = frozenset({"runner", "rustc", "rustc-wrapper", "rustc-workspace-wrapper", "rustdoc",
                                 "linker", "ar", "include", "paths", "patch", "path", "replace-with",
                                 "directory", "local-registry"})
NPMRC_EXECUTOR_KEYS = frozenset({"script-shell", "shell", "node-options", "userconfig", "globalconfig",
                                 "onload-script", "shell-emulator", "use-node-version", "node-version",
                                 "npm-path", "global-pnpmfile", "pnpmfile"})
YARNRC_EXECUTOR_KEYS = frozenset({"script-shell", "yarn-path", "yarnPath", "plugins", "injectEnvironmentFiles"})
GOENV_EXECUTOR_KEYS = frozenset({"GOFLAGS", "GOTOOLCHAIN", "GOROOT", "GOWORK", "CC", "CXX", "AR", "GOENV"})


def _toml_keys(value: Any) -> list[tuple[str, Any]]:
    found: list[tuple[str, Any]] = []
    if isinstance(value, dict):
        for name, item in value.items():
            found.append((str(name), item))
            found += _toml_keys(item)
    elif isinstance(value, list):
        for item in value:
            found += _toml_keys(item)
    return found


def _executor_override(path: Path, kind: str) -> str | None:
    """The executor-replacing setting `path` sets, if any; unreadable refuses."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError):
        return "unreadable"
    if kind == "cargo":
        if tomllib is None:
            return "unparseable without tomllib" if text.strip() else None
        try:
            document = tomllib.loads(text)
        except ValueError:
            return "unparseable"
        for name, value in _toml_keys(document):
            if name in CARGO_EXECUTOR_KEYS:
                return name
            if name in ("rustflags", "rustdocflags") and "linker" in json.dumps(value):
                return name + " linker"
        return None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if kind == "pytest":
            return "pytest configuration above the checkout"
        if kind == "yarnrc" and line.startswith("--"):
            return line.split()[0]
        name = re.split(r"[\s=:]", line, maxsplit=1)[0].strip("\"'")
        keys = {"npmrc": NPMRC_EXECUTOR_KEYS, "yarnrc": YARNRC_EXECUTOR_KEYS, "goenv": GOENV_EXECUTOR_KEYS}[kind]
        if name in keys or kind == "npmrc" and name.lower() in keys:
            return name
    return None


# Executor settings whose value is one program or path. Committed in the
# tree, one is allowed only as a tracked path inside the tree, whose bytes
# the tree key then binds; an absolute, PATH-resolved or outside value
# refuses, as does every other executor setting (r151-reuse4 R1).
PATH_EXECUTOR_KEYS = frozenset({"runner", "rustc", "rustc-wrapper", "rustc-workspace-wrapper", "rustdoc", "linker",
                                "ar", "path", "directory", "local-registry", "script-shell", "shell", "yarn-path",
                                "yarnPath"})
COMMITTED_CONFIGS = {"package": ((".npmrc", "npmrc"), (".yarnrc", "yarnrc"), (".yarnrc.yml", "yarnrc")),
                     "cargo": ((".cargo/config", "cargo"), (".cargo/config.toml", "cargo"))}
# The native stages' Cargo adapter runs cargo from / with a private, fresh
# CARGO_HOME (scripts/tests/helpers/native-cargo-home.py), so the only Cargo
# configuration they load is /.cargo/config*.
NATIVE_CARGO_CWD = Path("/")


def _config_settings(text: str, kind: str) -> list[tuple[str, Any]]:
    if kind == "cargo":
        if tomllib is None:
            raise ValueError("unparseable without tomllib")
        return _toml_keys(tomllib.loads(text))
    settings: list[tuple[str, Any]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        parts = re.split(r"\s*[=:]\s*|\s+", line, maxsplit=1)
        settings.append((parts[0].strip("\"'"), parts[1].strip().strip("\"'") if len(parts) > 1 else ""))
    return settings


DIRECTORY_KEYS = frozenset({"path", "directory", "local-registry"})


def _tracked_in_tree(root: Path, value: Any, directory: bool = False) -> bool:
    if isinstance(value, list):
        value = value[0] if value else None
    if not isinstance(value, str) or not value.split():
        return False
    program = value.split()[0]
    # A program named without a "/" is looked up on PATH; a directory is not.
    if program.startswith(("/", "~", "$")) or "/" not in program and not directory or ".." in program.split("/"):
        return False
    entry = git(root, "ls-tree", "HEAD", "--", posixpath.normpath(program))
    return entry.startswith((b"100644 blob ", b"100755 blob ", b"040000 tree "))


def committed_executor_refusal(root: Path, used: set[str]) -> str | None:
    """The committed config setting that names an executor outside the tree, if any."""
    files = (COMMITTED_CONFIGS["package"] if used & PACKAGE_MANAGERS else ()) + \
        (COMMITTED_CONFIGS["cargo"] if "cargo" in used else ())
    for name, kind in files:
        text = _committed_text(root, name)
        if text is None:
            continue
        keys = {"npmrc": NPMRC_EXECUTOR_KEYS, "yarnrc": YARNRC_EXECUTOR_KEYS, "cargo": CARGO_EXECUTOR_KEYS}[kind]
        try:
            settings = _config_settings(text, kind)
        except ValueError:
            return name + " (unparseable)"
        for setting, value in settings:
            if kind == "yarnrc" and setting.startswith("--"):
                return "{} ({})".format(name, setting)
            if kind == "cargo" and setting in ("rustflags", "rustdocflags") and "linker" in json.dumps(value):
                return "{} ({} linker)".format(name, setting)
            canonical = setting.lower() if kind == "npmrc" else setting
            if canonical not in keys:
                continue
            if kind == "cargo" and isinstance(value, dict):
                continue  # A table ([patch], [source]): its own keys are checked in turn.
            if canonical not in PATH_EXECUTOR_KEYS or not _tracked_in_tree(root, value, canonical in DIRECTORY_KEYS):
                return "{} ({})".format(name, setting)
    return None


def native_cargo_configs() -> dict[str, str | None]:
    """The Cargo configuration the native stages load, keyed; an executor refuses."""
    paths = [parent / ".cargo" / name for parent in (NATIVE_CARGO_CWD, *NATIVE_CARGO_CWD.parents)
             for name in ("config", "config.toml")]
    for path in paths:
        override = _executor_override(path, "cargo")
        if override is not None:
            raise ValueError("Cargo configuration for the native stages replaces the test executor: {} ({})"
                             .format(path, override))
    return {str(path): _file_identity(path) for path in paths}


def external_configs(root: Path, runners: list[str], wrappers: list[str]) -> dict[str, str | None]:
    """Configuration outside the tree that the command's runners read (r151 N3/N4).

    Keyed by content, present or absent: cargo's home and ancestor
    .cargo/config, the package managers' user and global rc files, Go's env
    file, uv and pdm user config, and the interpreter a uv or pdm project
    environment runs. A setting that replaces the executor or script shell,
    or redirects to unbound code (a Cargo runner or path override, an npm
    script-shell or node-options, a Yarn yarnPath, a Go GOFLAGS or
    toolchain), refuses instead (r151 F1), as does an ancestor pytest
    configuration or conftest.py, or an ancestor go.work.
    """
    home = _home()
    ancestors = list(root.resolve().parents)
    xdg = Path(os.environ.get("XDG_CONFIG_HOME") or str(home / ".config"))
    paths: list[tuple[Path, str | None]] = []
    used = set(runners) | set(wrappers)
    if "cargo" in used:
        paths += [(home / ".cargo" / name, "cargo") for name in ("config", "config.toml")]
        paths += [(parent / ".cargo" / name, "cargo") for parent in ancestors for name in ("config", "config.toml")]
    if "pytest" in used:
        paths += [(parent / name, "pytest") for parent in ancestors for name in (*PYTEST_CONFIGS, "conftest.py")]
    if "go" in used:
        paths += [(xdg / "go" / "env", "goenv"), (home / "Library/Application Support/go/env", "goenv")]
        paths += [(parent / "go.work", "pytest") for parent in ancestors]  # Any content refuses.
    if used & PACKAGE_MANAGERS:
        paths.append((home / ".npmrc", "npmrc"))
        # Every ancestor rc from the checkout up to / (Yarn reads them; npm
        # and pnpm are inventoried alike): an executor setting refuses.
        paths += [(parent / name, kind) for parent in ancestors for name, kind in COMMITTED_CONFIGS["package"]]
    committed = committed_executor_refusal(root, used)
    if committed is not None:
        raise ValueError("committed configuration names a test executor outside the tree: " + committed)
    if "npm" in used:
        node = shutil.which("node")
        npm = shutil.which("npm")
        if node:
            paths.append((Path(node).resolve().parent.parent / "etc" / "npmrc", "npmrc"))
        if npm:
            paths.append((Path(npm).resolve().parent.parent / "npmrc", "npmrc"))
    if "pnpm" in used:
        paths += [(xdg / "pnpm" / "rc", "npmrc"), (home / "Library/Preferences/pnpm/rc", "npmrc")]
    if "yarn" in used:
        paths += [(home / ".yarnrc", "yarnrc"), (home / ".yarnrc.yml", "yarnrc")]
    if used & {"uv", "pdm"}:
        paths += [(xdg / "uv" / "uv.toml", None), (xdg / "pdm" / "config.toml", None)]
    for path, kind in paths:
        override = _executor_override(path, kind) if kind is not None else None
        if override is not None:
            raise ValueError("configuration outside the tree replaces the test executor: {} ({})".format(path, override))
    identities: dict[str, str | None] = {str(path): _file_identity(path) for path, _kind in paths}
    if used & {"uv", "pdm"}:
        venv = root / ".venv" / "bin" / "python"
        identities["venv-python"] = (str(venv.resolve()) + " " + digest(venv.resolve().read_bytes())
                                     if venv.exists() else None)
    return identities


def trusted_gate_policy(root: Path) -> tuple[str, list[str]]:
    """(identity, names) of the remote-default gate.env_passthrough policy.

    The managed dispatcher forwards exactly these names (attachment.sh
    trellis_collect_gate_env), so forwarding and keying share one policy: the
    origin/HEAD .trellis.json. Identity is its blob, or "none" when there is no
    valid policy and the dispatcher forwards nothing.
    """
    try:
        if git(root, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD").strip() == b"":
            return "none", []
        commit = git(root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/HEAD^{commit}").decode().strip()
        records = git(root, "ls-tree", "-z", commit, "--", ".trellis.json").split(b"\0")
    except subprocess.CalledProcessError:
        return "none", []
    match = re.fullmatch(rb"(?:100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64})\t\.trellis\.json", records[0])
    if len(records) != 2 or match is None:
        return "none", []
    blob = match.group(1).decode("ascii")
    try:
        document = json.loads(git(root, "cat-file", "blob", blob).decode("utf-8"), object_pairs_hook=_unique_object)
    except (subprocess.CalledProcessError, UnicodeError, ValueError):
        return "none", []
    gate = document.get("gate", {}) if isinstance(document, dict) else None
    if (not isinstance(gate, dict) or set(gate) - {"env_passthrough", "verdict_reuse", "docs_only_tests"}
            or not isinstance(gate.get("verdict_reuse", True), bool)
            or not isinstance(gate.get("docs_only_tests", True), bool)):
        return "none", []
    names = gate.get("env_passthrough", [])
    if (not isinstance(names, list) or not all(isinstance(name, str) for name in names)
            or len(names) != len(set(names)) or not all(_passthrough_name_allowed(name) for name in names)):
        return "none", []
    return blob, sorted(names)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name, value in pairs:
        if name in result:
            raise ValueError("duplicate JSON key")
        result[name] = value
    return result


# Mirrors the dispatcher's reserved names and prefixes; a name it would refuse
# makes the whole list invalid there, so it does here too.
PASSTHROUGH_RESERVED = {
    "PATH", "HOME", "TMP", "TMPDIR", "TEMP", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "IFS", "CDPATH",
    "NODE_OPTIONS", "DOCKER_HOST", "DOCKER_CONTEXT", "POSIXLY_CORRECT", "ZDOTDIR", "RUBYOPT", "PERL5OPT",
    "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "PWD", "OLDPWD", "SHLVL", "_", "LANG", "LANGUAGE", "TZ",
    "NODE_PATH", "NODE_REPL_EXTERNAL_MODULE", "NODE_EXTRA_CA_CERTS", "NODE_ICU_DATA", "NODE_V8_COVERAGE",
    "RANDOM", "SRANDOM", "SECONDS", "LINENO", "OPTIND", "OPTARG", "PPID", "UID", "EUID", "GROUPS", "DIRSTACK",
    "FUNCNAME", "PIPESTATUS", "SHELL", "PS1", "PS2", "PS3", "PS4"}
PASSTHROUGH_PREFIXES = ("XDG_", "TMP", "TEMP", "GIT_", "TRELLIS_", "PROCESS_GATE_", "SECURITY_GATE_", "PYTHON",
                        "BASH", "LD_", "DYLD_", "CALLER_", "LC_", "DOCKER_", "COREPACK_", "PERL", "RUBY", "GEM_",
                        "GH_")


def _passthrough_name_allowed(name: str) -> bool:
    upper = name.upper()
    return (re.fullmatch("[A-Za-z_][A-Za-z0-9_]*", name) is not None
            and not any(secret in upper for secret in ("TOKEN", "SECRET", "KEY", "PASSWORD"))
            and upper not in PASSTHROUGH_RESERVED and not upper.startswith(PASSTHROUGH_PREFIXES))


def gate_runner(extra: tuple[str, ...] = ()) -> dict[str, str]:
    """Digest the gate code that runs and records a project command."""
    here = Path(__file__).resolve().parent
    files = {name: digest((here / name).read_bytes()) for name in GATE_MODULES}
    for name in extra:
        path = Path(name).resolve(strict=True)
        files[path.name] = digest(path.read_bytes())
    return files


def native_cargo_identity(root: Path, version_probe=probe) -> dict[str, Any]:
    """Bind the pinned compiler and offline inputs selected by test helpers."""
    helper = Path(__file__).resolve().parent.parent / "tests/helpers/native-cargo-home.py"
    try:
        spec = importlib.util.spec_from_file_location("trellis_native_cargo_home", helper)
        if spec is None or spec.loader is None:
            raise ValueError("native Cargo helper cannot be loaded")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        unavailable: list[str] = []
        try:
            env = dict(os.environ, RUSTUP_AUTO_INSTALL="0", CARGO_NET_OFFLINE="true")
            def rustc_probe(path):
                answer = version_probe([str(path), "-vV"], env, root)
                if not answer.strip() or answer.startswith("unavailable:"):
                    unavailable.append(str(path))
                return answer
            identity = module.fixture_identity(root / "native/trellis-hooks/Cargo.lock", rustc_probe)
        except module.MissingPrerequisite as error:
            raise ValueError(str(error)) from error
        except ValueError as error:
            # A probe that timed out costs reuse only; the run stays tracked
            # so a failure still supersedes an earlier pass.
            if unavailable and not isinstance(error, ProbeUnavailable):
                raise ProbeUnavailable("native rustc probe failed: " + ", ".join(unavailable)) from error
            raise
        if unavailable:
            # A later candidate answered, but the stage's own (longer) probe
            # may select the one that timed out here (r151-reuse4 R5).
            raise ProbeUnavailable("native rustc probe failed: " + ", ".join(unavailable))
        return identity
    except ImportError as error:
        raise ValueError("native Cargo helper unavailable") from error


def capture_inputs(root: Path, gated_head: str = "HEAD", version_probe=probe,
                   command: str = LOCAL_RUNNER_COMMAND, runner: dict[str, str] | None = None,
                   tools: dict[str, Any] | None = None) -> dict[str, Any]:
    """Key a pass on the committed tree, test command, runner, toolchain, platform and keyed env.

    Refs, Git config and unlisted environment are deliberately not keyed:
    they differ between checkouts and sessions without changing what a clean
    tree's tests do. A dirty tree, a narrowed, test-seam or injected run, an
    ignored file the runner may discover, or an opted-out project refuses
    instead of producing a key. `tools` reuses a toolchain captured at the
    start of the same run instead of probing it again.
    """
    if not command:
        raise ValueError("no test command")
    allowed, head_names = project_gate_policy(root)
    # One trusted policy (r151 N2): the names the managed dispatcher forwards
    # from origin/HEAD, and its identity, which must be the one the dispatcher
    # used. HEAD-declared names only add keys.
    policy, trusted_names = trusted_gate_policy(root)
    forwarded = os.environ.get("TRELLIS_GATE_ENV_POLICY")
    if forwarded is not None and forwarded != policy:
        raise ValueError("gate env policy differs from the one the dispatcher forwarded")
    environment = keyed_environment(sorted(set(trusted_names) | set(head_names)))
    head = git(root, "rev-parse", "--verify", "HEAD^{commit}").strip()
    if git(root, "rev-parse", "--verify", gated_head + "^{commit}").strip() != head:
        raise ValueError("checkout HEAD is not the gated head")
    if git(root, "status", "--porcelain=v1", "--untracked-files=all"):
        raise ValueError("checkout is not clean")
    if command == LOCAL_RUNNER_COMMAND:
        if git(root, "ls-files", "-z", "-o", "-i", "--exclude-standard", "--",
               *(":(glob)" + pattern for pattern in DISCOVERY_GLOBS)):
            raise ValueError("ignored file matches suite discovery")
        configs: dict[str, str | None] = native_cargo_configs()
        native: dict[str, str] = {"native": native_decision(root)}
    else:
        runners, wrappers, roots = command_runners(root, command)
        ignored = ignored_files_refusal(root, runners, roots)
        if ignored is not None:
            raise ValueError("ignored file the test runner may discover: " + ignored)
        reporter = config_reporter_refusal(root, runners)
        if reporter is not None:
            raise ValueError("committed runner configuration names a reporter outside the tree: " + reporter)
        configs = external_configs(root, runners, wrappers)
        native = {}
    link = escaping_symlink(root)
    if link is not None:
        raise ValueError("tracked symlink leaves the tree: " + link)
    if any(entry[:1].islower() or entry.startswith(b"S ") for entry in git(root, "ls-files", "-v", "-z").split(b"\0") if entry):
        raise ValueError("assume-unchanged or skip-worktree checkout")
    if not allowed:
        raise ValueError("verdict reuse disabled by .trellis.json gate.verdict_reuse")
    if runner is None:
        runner = {name: digest((root / name).read_bytes()) for name in RUNNER_FILES}
    tree = git(root, "rev-parse", "HEAD^{tree}").decode().strip()
    try:
        # Probed last: every refusal above has already passed.
        tools = tools if tools is not None else toolchain(root, version_probe)
        native_cargo = native_cargo_identity(root, version_probe) if command == LOCAL_RUNNER_COMMAND else None
    except ProbeUnavailable as error:
        error.scope = {"schema": SCHEMA, "tree": tree, "command": command}
        raise
    inputs = {"schema": SCHEMA, "tree": tree,
              "command": command, "runner": runner, "env": environment, "policy": policy, "configs": configs,
              "toolchain": tools,
              "platform": [sys.platform, platform.release(), platform.machine()]} | native
    if native_cargo is not None:
        inputs["native_cargo"] = native_cargo
    return inputs


def safe_inputs(root: Path, gated_head: str = "HEAD", version_probe=probe, **kwargs: Any) -> dict[str, Any] | None:
    try:
        return capture_inputs(root, gated_head, version_probe, **kwargs)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None  # A miss always executes the real battery.


def find_verdict(inputs: dict[str, Any] | None, state: Path | None = None, *, occupancy: bool = True) -> dict[str, Any] | None:
    if inputs is None:
        return None
    try:
        state = state if state is not None else state_root()
        directory = state / "verdicts"
        path = directory / (key(inputs) + ".json")
        if ((occupancy and ((state / "gate-holder.json").exists() or any((state / "runs").glob("*.json"))))
                or (state / "reuse-disabled.json").exists()
                or not all((private(state, True), private(directory, True), private(path)))):
            return None
        record = json.loads(path.read_text(encoding="utf-8"))
        if (record["schema"] != SCHEMA or record["key"] != key(inputs) or record["inputs"] != inputs
                or record["status"] != "pass" or record["complete"] is not True
                or record["containment"] != "verified-empty"
                or not re.fullmatch(r"[0-9a-f]{32}", record["id"])
                or not math.isfinite(record["completed_at"]) or record["completed_at"] <= 0
                or not 0 <= time.time() - record["completed_at"] <= MAX_VERDICT_AGE_SECONDS):
            return None
        parent = state / "passing-runs"
        kept = parent / record["id"]
        aggregate, metadata = kept / "aggregate.tsv", kept / "run.json"
        if not all((private(parent, True), private(kept, True), private(aggregate), private(metadata))):
            return None
        content = aggregate.read_bytes()
        passing_rows(content)
        run = json.loads(metadata.read_text(encoding="utf-8"))
        if (record["aggregate_sha256"] != digest(content) or run["aggregate_sha256"] != digest(content)
                or run["id"] != record["id"] or run["tree"] != inputs["tree"]
                or run["completed_at"] != record["completed_at"]):
            return None
        return record
    except (OSError, ValueError, KeyError, TypeError):
        return None


def tree_verdicts(tree: str, state: Path) -> list[dict[str, Any]]:
    """Snapshot valid tree matches before an uncached run invalidates them."""
    directory = state / "verdicts"
    try:
        if not private(state, True) or not private(directory, True):
            return []
    except OSError:
        return []
    records = []
    for path in sorted(directory.glob("*.json")):
        try:
            if not private(path):
                continue
            inputs = json.loads(path.read_text(encoding="utf-8"))["inputs"]
            if inputs["tree"] != tree or path.name != key(inputs) + ".json":
                continue
            record = find_verdict(inputs, state, occupancy=False)
            if record is not None:
                records.append(record)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return records


def describe(record: dict[str, Any]) -> str:
    import datetime
    date = datetime.datetime.fromtimestamp(record["completed_at"], datetime.timezone.utc).isoformat()
    return "reused verdict {} (tree {}, ran {})".format(record["id"], record["inputs"]["tree"], date)


# Project command verdicts. process-gate records one only after the command
# exited 0 for a full (never narrowed) run and the inputs were unchanged by it.
# They live in the Trellis-guarded state area, which the PreToolUse guards keep
# agent tools from writing (Write/Edit targets, including hard links to stored
# files, and shell commands naming a gate-verdicts path or moving its parents).
# Each verdict names a retained execution log by sha256.
# A verdict or log with a second name is a miss. A process of the same UID
# outside an agent tool can still forge both; see
# references/tests.md "Verdict reuse".
STORE_NAME = "gate-verdicts"
DISABLE_MARKER = "reuse-disabled"


def command_store() -> Path:
    home = os.environ.get("TRELLIS_HOME") or os.environ.get("HOME", "") + "/.trellis"
    root = Path(home)
    if not root.is_absolute():
        raise ValueError("TRELLIS_HOME must be absolute")
    resolved = root.resolve()
    if any((parent / ".git").exists() or (parent / ".git").is_symlink()
           for parent in (resolved, *resolved.parents)):
        raise ValueError("verdict store must be outside every checkout")
    return root / "state" / STORE_NAME


def command_reuse_disabled(store: Path) -> bool:
    """The machine kill switch, or the weekly backstop's P1 marker."""
    if os.path.lexists(store / DISABLE_MARKER):
        return True
    try:
        return (state_root() / "reuse-disabled.json").exists()
    except (OSError, ValueError):
        return True


def failure_name(inputs: dict[str, Any]) -> str:
    return digest(encoded([inputs["tree"], inputs["command"]])) + ".json"


def _failed_since(store: Path, inputs: dict[str, Any], since: float) -> bool:
    """A failing run of this tree and command recorded at or after `since`."""
    path = store / "failures" / failure_name(inputs)
    if not os.path.lexists(path):
        return False
    try:
        if not private(path):
            return True
        failed_at = json.loads(path.read_text(encoding="utf-8"))["failed_at"]
        return not (isinstance(failed_at, (int, float)) and math.isfinite(failed_at)) or failed_at >= since
    except (OSError, ValueError, KeyError, TypeError):
        return True  # An unreadable tombstone never lets a pass through.


STORE_DIRS = ("verdicts", "logs", "failures", "inflight")
# An intent whose owner still runs after this long is resolved as a failure.
INTENT_MAX_AGE_SECONDS = 86400


def store_unhealthy(store: Path) -> str | None:
    """Why the store's metadata cannot be trusted, if it cannot (r151 N9)."""
    try:
        if not private(store, True):
            return "verdict store is not owner-private"
        for name in STORE_DIRS:
            if os.path.lexists(store / name) and not private(store / name, True):
                return "verdict store {}/ is not owner-private".format(name)
        lock = store / ".lock"
        if os.path.lexists(lock):
            info = lock.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                return "verdict store lock is not an owner-private file"
    except OSError as error:
        return "verdict store is unreadable: " + str(error)
    return None


def _intent_stem(inputs: dict[str, Any]) -> str:
    return failure_name(inputs)[:-len(".json")]


def _intents(store: Path, inputs: dict[str, Any]) -> list[tuple[Path, dict[str, Any] | None]]:
    """Every unresolved run of this tree and command; an unreadable one has no record."""
    found: list[tuple[Path, dict[str, Any] | None]] = []
    for path in sorted((store / "inflight").glob(_intent_stem(inputs) + ".*.json")):
        try:
            record = json.loads(path.read_text(encoding="utf-8")) if private(path) else None
            if record is not None and not (isinstance(record.get("pid"), int)
                                           and isinstance(record.get("started_at"), (int, float))):
                record = None
        except (OSError, ValueError):
            record = None
        found.append((path, record))
    return found


def _owner_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _tombstone(store: Path, inputs: dict[str, Any], failed_at: float) -> None:
    """Record a failure of this tree and command no earlier than `failed_at`."""
    path = store / "failures" / failure_name(inputs)
    try:
        previous = json.loads(path.read_text(encoding="utf-8"))["failed_at"] if private(path) else None
    except (OSError, ValueError, KeyError, TypeError):
        previous = None
    if isinstance(previous, (int, float)) and math.isfinite(previous) and previous >= failed_at:
        return
    _write_private_json(path, {"tree": inputs["tree"], "command": inputs["command"], "failed_at": failed_at})


def _resolve_abandoned(store: Path, inputs: dict[str, Any], now: float, keep: str | None = None) -> None:
    """An intent whose owner exited without finalizing counts as a failure.

    Its failure is dated when it is resolved, not when it started (r151 F9):
    the run may have failed at any point of its unresolved interval, so every
    pass that completed, or started, before now is superseded.
    """
    for path, record in _intents(store, inputs):
        if keep is not None and path.name == "{}.{}.json".format(_intent_stem(inputs), keep):
            continue
        if record is not None and _owner_alive(record["pid"]) and now - record["started_at"] <= INTENT_MAX_AGE_SECONDS:
            continue
        _tombstone(store, inputs, now)
        path.unlink(missing_ok=True)


def single(path: Path) -> bool:
    """One name only: a hard link elsewhere may have changed the bytes."""
    return path.lstat().st_nlink == 1


def find_command_verdict(inputs: dict[str, Any] | None, store: Path | None = None) -> dict[str, Any] | None:
    if inputs is None:
        return None
    try:
        store = store if store is not None else command_store()
        directory, logs = store / "verdicts", store / "logs"
        path = directory / (key(inputs) + ".json")
        if (command_reuse_disabled(store) or store_unhealthy(store) is not None
                or not all((private(store, True), private(directory, True), private(path), single(path)))
                or _intents(store, inputs)):
            return None  # Disabled, untrusted metadata, a second name, or a run of these inputs is unresolved.
        record = json.loads(path.read_text(encoding="utf-8"))
        if (record["schema"] != SCHEMA or record["kind"] != "command" or record["key"] != key(inputs)
                or record["inputs"] != inputs or record["status"] != "pass" or record["complete"] is not True
                or not re.fullmatch(r"[0-9a-f]{32}", record["id"])
                or not math.isfinite(record["completed_at"]) or record["completed_at"] <= 0
                or not 0 <= time.time() - record["completed_at"] <= MAX_VERDICT_AGE_SECONDS):
            return None
        log = logs / (record["id"] + ".log")
        if (not private(logs, True) or not private(log) or not single(log)
                or digest(log.read_bytes()) != record["log_sha256"]
                or _failed_since(store, inputs, record["completed_at"])):
            return None
        return record
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not private(path, True):
        raise ValueError("verdict directory is not owner-private: " + str(path))


def _write_private(path: Path, content: bytes) -> None:
    temporary = path.with_name(".{}.{}.tmp".format(path.name, os.getpid()))
    fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _write_private_json(path: Path, value: dict[str, Any]) -> None:
    _write_private(path, json.dumps(value, sort_keys=True).encode("utf-8"))


class _StoreLock:
    """Serialise every command-verdict mutation (intent, record, fail, prune)."""

    def __init__(self, store: Path) -> None:
        _private_directory(store)
        for name in STORE_DIRS:
            _private_directory(store / name)
        self.fd = os.open(str(store / ".lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        info = os.fstat(self.fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            os.close(self.fd)
            raise ValueError("verdict store lock is not an owner-private file")
        problem = store_unhealthy(store)
        if problem is not None:
            os.close(self.fd)
            raise ValueError(problem)

    def __enter__(self) -> "_StoreLock":
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc: object) -> None:
        os.close(self.fd)


def _prune(store: Path, now: float) -> None:
    for path in (store / "verdicts").glob("*.json"):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
            if now - record["completed_at"] > MAX_VERDICT_AGE_SECONDS:
                path.unlink()
        except (OSError, ValueError, KeyError, TypeError):
            continue
    for folder in ("logs", "failures"):
        for path in (store / folder).iterdir():
            try:
                if now - path.lstat().st_mtime > MAX_VERDICT_AGE_SECONDS + 3600:
                    path.unlink()
            except OSError:
                continue


class TrackingUnavailable(Exception):
    """No durable intent could be persisted: the run must not execute."""


class StoreMovedAside(Exception):
    """A miss whose intent is tracked in a fresh store; the old one was unhealthy."""

    def __init__(self, message: str, ident: str, started: float) -> None:
        super().__init__(message)
        self.ident, self.started = ident, started


def begin_command_run(inputs: dict[str, Any], owner_pid: int, *, reuse: bool = True,
                      store: Path | None = None) -> tuple[dict[str, Any] | None, str | None, float]:
    """Look up a pass, or persist this run's intent before it executes (r151 N8/N9).

    Returns (reused record, None, 0) on a hit, else (None, intent id, start).
    The intent blocks every lookup of the same tree and command until the run
    records, fails, or is released; an owner that exits first counts as a
    failure. `reuse=False` (a forced-full run) never reads a pass but still
    tracks its failure.
    """
    store = store if store is not None else command_store()
    ident = os.urandom(16).hex()
    intent = store / "inflight" / "{}.{}.json".format(_intent_stem(inputs), ident)
    content = {"tree": inputs["tree"], "command": inputs["command"], "key": key(inputs), "pid": owner_pid}
    try:
        with _StoreLock(store):
            now = time.time()
            _resolve_abandoned(store, inputs, now)
            record = find_command_verdict(inputs, store) if reuse else None
            if record is not None:
                return record, None, 0.0
            _write_private_json(intent, dict(content, started_at=now))
            return None, ident, now
    except (OSError, ValueError) as error:
        problem = error
    # Durable failure tracking could not be set up (r151 F10). Never run
    # untracked against this store: a failure it cannot record would let a
    # repair revive the passes that failure superseded. Move the store aside,
    # so none of its passes is read again, and track the run in a fresh one.
    # Only a store that cannot be moved aside stops the run (TrackingUnavailable).
    aside = store.with_name("{}.unhealthy-{}-{}".format(store.name, int(time.time()), os.urandom(4).hex()))
    try:
        os.rename(store, aside)
    except FileNotFoundError:
        pass  # A concurrent gate moved it first.
    except OSError as error:
        raise TrackingUnavailable("verdict store {} is unhealthy ({}) and cannot be moved aside: {}".format(
            store, problem, error)) from error
    try:
        with _StoreLock(store):
            now = time.time()
            _write_private_json(intent, dict(content, started_at=now))
    except (OSError, ValueError) as error:
        # No pass is left at the store path for a repair to revive, so the run
        # may execute untracked; the error is still reported.
        raise ValueError("verdict store {} cannot be created: {}".format(store, error)) from error
    raise StoreMovedAside("verdict store was unhealthy ({}); moved aside to {}".format(problem, aside), ident, now)


def _end_intent(store: Path, inputs: dict[str, Any], ident: str) -> bool:
    path = store / "inflight" / "{}.{}.json".format(_intent_stem(inputs), ident)
    existed = os.path.lexists(path)
    path.unlink(missing_ok=True)
    return existed


def release_command_run(inputs: dict[str, Any], ident: str, store: Path | None = None) -> None:
    """A run that passed but publishes nothing (not full): drop its intent only."""
    store = store if store is not None else command_store()
    with _StoreLock(store):
        _end_intent(store, inputs, ident)


def invalidate_command_verdicts(inputs: dict[str, Any], store: Path | None = None, ident: str | None = None) -> None:
    """A failing run of a tree and command supersedes every pass for it, atomically.

    Under the store lock it records a failure tombstone, so a pass whose run
    started before this failure can no longer be recorded, then deletes every
    pass and log for the same tree and command, then ends its intent. Any
    error propagates: the intent then stays, and blocks reuse.
    """
    store = store if store is not None else command_store()
    with _StoreLock(store):
        now = time.time()
        _tombstone(store, inputs, now)
        for path in (store / "verdicts").glob("*.json"):
            try:
                record = json.loads(path.read_text(encoding="utf-8"))
                recorded = record["inputs"]
            except (OSError, ValueError, KeyError, TypeError):
                continue
            if recorded.get("tree") == inputs["tree"] and recorded.get("command") == inputs["command"]:
                path.unlink()
                if re.fullmatch(r"[0-9a-f]{32}", str(record.get("id"))):
                    (store / "logs" / (record["id"] + ".log")).unlink(missing_ok=True)
        if ident is not None:
            _end_intent(store, inputs, ident)
        _resolve_abandoned(store, inputs, now)


def record_command_verdict(before: dict[str, Any] | None, after: dict[str, Any] | None,
                           store: Path | None = None, *, output: bytes = b"",
                           started_at: float | None = None, ident: str | None = None) -> dict[str, Any] | None:
    if before is None:
        return None
    store = store if store is not None else command_store()
    started_at = time.time() if started_at is None else started_at
    with _StoreLock(store):
        if ident is not None and not _end_intent(store, before, ident):
            return None  # The intent was resolved as abandoned: never publish.
        if after != before or command_reuse_disabled(store):
            return None  # Inputs changed during the run, or reuse is disabled.
        now = time.time()
        _resolve_abandoned(store, before, now)
        if _failed_since(store, before, started_at):
            return None  # An overlapping run of the same inputs failed.
        _prune(store, now)
        name, run_id = key(before), os.urandom(16).hex()
        log = ("trellis gate verdict log\nid: {}\ntree: {}\ncommand: {}\nexit: 0\n---\n".format(
            run_id, before["tree"], json.dumps(before["command"]))).encode("utf-8") + output
        _write_private(store / "logs" / (run_id + ".log"), log)
        record = {"schema": SCHEMA, "kind": "command", "key": name, "inputs": before,
                  "status": "pass", "complete": True, "id": run_id, "completed_at": now,
                  "log_sha256": digest(log)}
        _write_private_json(store / "verdicts" / (name + ".json"), record)
    return record


def _open_inputs_file(path: Path, flags: int) -> int:
    """The gate's mktemp inputs file: a private regular file, never a link."""
    fd = os.open(str(path), flags | os.O_NOFOLLOW)
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        os.close(fd)
        raise ValueError("unsafe verdict inputs file")
    return fd


def _read_saved(path: Path) -> tuple[dict[str, Any], float, str] | None:
    with os.fdopen(_open_inputs_file(path, os.O_RDONLY), "rb") as stream:
        content = stream.read(4 * 1024 * 1024 + 1)
    if not content:
        return None
    saved = json.loads(content.decode("utf-8"))
    started_at, ident = saved["started_at"], saved["intent"]
    if (not isinstance(saved["inputs"], dict) or not isinstance(started_at, (int, float))
            or not math.isfinite(started_at) or not 0 < started_at <= time.time()
            or not isinstance(ident, str) or not re.fullmatch(r"[0-9a-f]{32}", ident)):
        raise ValueError("invalid saved verdict inputs")
    return saved["inputs"], float(started_at), ident


def _cli(argv: list[str]) -> int:
    """process-gate interface for project test commands.

    lookup --head=SHA --command=CMD --save=FILE --owner-pid=PID [--no-reuse] [--runner=FILE ...]
        exit 0 and print the reused verdict on a hit; on a miss persist the
        run's intent, save the inputs, start time and intent to FILE, exit 1.
        --no-reuse (a forced-full run) never hits but still tracks the run.
    record --head=SHA --command=CMD --save=FILE [--runner=FILE ...] --log=-
        recapture after a passing full run; write a verdict, retaining the
        run's output read from stdin, only if the inputs are unchanged.
    release --head=SHA --command=CMD --save=FILE [--runner=FILE ...]
        a passing run that publishes nothing: end its intent.
    forget --head=SHA --command=CMD --save=FILE [--runner=FILE ...]
        after a failing run, drop every pass for this tree and command.
    A miss exits 1 (a notice, such as an unhealthy store moved aside, is
    printed on stderr); a store error is printed on stderr and exits 2, and an
    unfinished intent then keeps blocking reuse. A lookup that cannot persist
    the run's intent exits 3: the gate must not run the command untracked.
    Usage errors exit 64.
    """
    if not argv or argv[0] not in ("lookup", "record", "release", "forget"):
        return 64
    options: dict[str, str] = {}
    runners: list[str] = []
    reuse = True
    for arg in argv[1:]:
        if arg == "--no-reuse" and argv[0] == "lookup" and reuse:
            reuse = False
            continue
        name, separator, value = arg.partition("=")
        if (not separator or not value
                or name not in ("--head", "--command", "--save", "--runner", "--log", "--owner-pid")):
            return 64
        if name == "--runner":
            runners.append(value)
        elif name[2:] in options:
            return 64
        else:
            options[name[2:]] = value
    required = ({"head", "command", "save"} | ({"log"} if argv[0] == "record" else set())
                | ({"owner-pid"} if argv[0] == "lookup" else set()))
    if (set(options) != required or not re.fullmatch(r"[0-9a-f]{40,64}", options["head"])
            or options.get("log", "-") != "-" or not re.fullmatch(r"[1-9][0-9]*", options.get("owner-pid", "1"))):
        return 64
    root = Path.cwd()
    save = Path(options["save"])
    try:
        if argv[0] != "lookup":
            saved = _read_saved(save)
            if saved is None:
                return 1
            before, started_at, ident = saved
            if argv[0] == "forget":
                # The saved pre-run inputs name the tree and command that failed.
                invalidate_command_verdicts(before, ident=ident)
                return 0
            if argv[0] == "release" or "toolchain" not in before:
                # A run tracked without inputs (a probe gave no answer) never
                # publishes; its pass only ends the intent.
                release_command_run(before, ident)
                return 0 if argv[0] == "release" else 1
            output = sys.stdin.buffer.read()
            after = (safe_inputs(root, options["head"], command=options["command"], runner=gate_runner(tuple(runners)),
                                 tools=before["toolchain"]) if toolchain_unchanged(before["toolchain"]) else None)
            record = record_command_verdict(before, after, output=output, started_at=started_at, ident=ident)
            if record is None:
                return 1
            print("recorded verdict {}".format(record["id"]))
            return 0
        # Probing the toolchain dominates capture time. After the run, re-verify
        # the head, a clean tree, the command, the runner and the keyed env,
        # re-hash the toolchain's executables, and key on the versions the run
        # started with.
        try:
            inputs = capture_inputs(root, options["head"], command=options["command"],
                                    runner=gate_runner(tuple(runners)))
        except ProbeUnavailable as error:
            # Reuse is lost, but a failure must still supersede earlier passes
            # for this tree and command: track the run by them alone.
            if error.scope is None:
                return 1
            inputs, reuse = error.scope, False
        except (OSError, ValueError, subprocess.SubprocessError):
            return 1  # Refused: this command never reads or writes the store.
        notice = None
        try:
            found, intent, started = begin_command_run(inputs, int(options["owner-pid"]), reuse=reuse)
        except StoreMovedAside as moved:
            found, intent, started, notice = None, moved.ident, moved.started, str(moved)
        except TrackingUnavailable as error:
            print("gate-verdict: lookup failed: {}".format(error), file=sys.stderr)
            return 3
        if found is not None:
            print(describe(found))
            return 0
        if notice is not None:
            print("gate-verdict: " + notice, file=sys.stderr)
        fd = _open_inputs_file(save, os.O_WRONLY)
        os.ftruncate(fd, 0)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(json.dumps({"inputs": inputs, "started_at": started, "intent": intent}, sort_keys=True))
        return 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print("gate-verdict: {} failed: {}".format(argv[0], error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(_cli(sys.argv[1:]))
