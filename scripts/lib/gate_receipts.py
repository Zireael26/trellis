"""Shared local-gate state location and strict passing timing receipts."""
from __future__ import annotations

import hashlib
import math
import os
from pathlib import Path
import stat

HEADER = "ordinal\tstage\telapsed_seconds\texit"


def state_root() -> Path:
    # Match pre-072 runners and cron even when agents set a different XDG root.
    home = os.environ.get("HOME", "")
    configured = os.environ.get("TRELLIS_GATE_STATE_DIR")
    root = Path(configured if configured is not None else home + "/.local/state/trellis-gate")
    if not root.is_absolute() or (configured is None and not Path(home).is_absolute()):
        raise ValueError("gate state root must be absolute")
    resolved = root.resolve()
    if any((parent / ".git").exists() or (parent / ".git").is_symlink()
           for parent in (resolved, *resolved.parents)):
        raise ValueError("gate state root must be outside every checkout")
    return root


def private(path: Path, directory: bool = False) -> bool:
    info = path.lstat()
    return (info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600)
            and (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)))


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def passing_rows(content: bytes) -> list[tuple[str, float]]:
    lines = content.decode("utf-8").splitlines()
    if not lines or lines[0] != HEADER or len(lines) < 2:
        raise ValueError("not a nonempty timing receipt")
    rows = []
    for ordinal, line in enumerate(lines[1:], 1):
        fields = line.split("\t")
        if len(fields) != 4 or fields[0] != str(ordinal) or not fields[1] or fields[3] != "0":
            raise ValueError("not a complete passing timing receipt")
        elapsed = float(fields[2])
        if not math.isfinite(elapsed) or elapsed < 0:
            raise ValueError("invalid stage timing")
        rows.append((fields[1], elapsed))
    if len({stage for stage, _ in rows}) != len(rows):
        raise ValueError("duplicate timing stage")
    return rows
