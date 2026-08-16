from __future__ import annotations

import os
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Mapping, Sequence

MAX_CAPTURE_BYTES = 4 * 1024 * 1024
_SECRET_NAMES = ("TOKEN", "SECRET", "PASSWORD", "API_KEY", "AUTHORIZATION", "COOKIE")


@dataclass(frozen=True)
class CaptureResult:
    argv: tuple[str, ...]
    exit_code: int
    started_at: str
    finished_at: str
    stdout_path: str
    stderr_path: str
    timed_out: bool = False


def capture_command(
    argv: Sequence[str],
    *,
    cwd: Path,
    output_dir: Path,
    name: str,
    timeout: float,
    env: Mapping[str, str] | None = None,
    stdin: bytes | None = None,
) -> CaptureResult:
    if not argv or any("\x00" in part for part in argv):
        raise ValueError("capture argv must contain non-NUL arguments")
    output_dir.mkdir(parents=True, exist_ok=True)
    effective_env = dict(os.environ if env is None else env)
    started = _now()
    timed_out = False
    try:
        completed = subprocess.run(
            list(argv),
            cwd=cwd,
            env=effective_env,
            input=stdin,
            capture_output=True,
            check=False,
            timeout=timeout,
        )
        stdout = completed.stdout[:MAX_CAPTURE_BYTES]
        stderr = completed.stderr[:MAX_CAPTURE_BYTES]
        exit_code = completed.returncode
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        stdout = _bytes(exc.stdout)[:MAX_CAPTURE_BYTES]
        stderr = _bytes(exc.stderr)[:MAX_CAPTURE_BYTES]
        exit_code = 124
    redactions = _redactions(effective_env)
    stdout = _sanitize(stdout, redactions)
    stderr = _sanitize(stderr, redactions)
    stdout_path = output_dir / f"{name}.stdout"
    stderr_path = output_dir / f"{name}.stderr"
    atomic_write(stdout_path, stdout)
    atomic_write(stderr_path, stderr)
    return CaptureResult(
        argv=tuple(_sanitize_text(part, redactions) for part in argv),
        exit_code=exit_code,
        started_at=started,
        finished_at=_now(),
        stdout_path=stdout_path.relative_to(output_dir.parent).as_posix(),
        stderr_path=stderr_path.relative_to(output_dir.parent).as_posix(),
        timed_out=timed_out,
    )


def atomic_write(path: Path, content: bytes | str) -> None:
    payload = content.encode("utf-8") if isinstance(content, str) else content
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def normalize_output_dir(path: Path, *, label: str) -> Path:
    if path.is_symlink():
        raise ValueError(f"{label} must not be a symlink")
    if not path.is_absolute() and ".." in path.parts:
        raise ValueError(f"relative {label} must not escape the current directory")
    cwd = Path.cwd().resolve()
    absolute = path if path.is_absolute() else cwd / path
    try:
        relative = absolute.relative_to(cwd)
    except ValueError:
        relative = None
    if relative is not None:
        candidate = cwd
        for part in relative.parts:
            candidate /= part
            if candidate.is_symlink():
                raise ValueError(f"{label} must not contain symlink components")
    return absolute.resolve(strict=False)


def _redactions(env: Mapping[str, str] | None) -> tuple[str, ...]:
    candidates = [str(Path.home())]
    if env:
        candidates.extend(
            value
            for name, value in env.items()
            if value and any(marker in name.upper() for marker in _SECRET_NAMES)
        )
    return tuple(sorted(set(candidates), key=len, reverse=True))


def local_ollama_env() -> dict[str, str]:
    allowed = ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL")
    environment = {name: os.environ[name] for name in allowed if name in os.environ}
    environment["OLLAMA_HOST"] = "http://127.0.0.1:11434"
    environment["NO_PROXY"] = "127.0.0.1,localhost"
    return environment


def _sanitize(payload: bytes, redactions: tuple[str, ...]) -> bytes:
    return _sanitize_text(payload.decode("utf-8", errors="replace"), redactions).encode(
        "utf-8"
    )


def validate_local_ollama_model(model: str) -> None:
    if (
        not model
        or model.startswith("-")
        or any(character.isspace() or ord(character) < 32 for character in model)
    ):
        raise ValueError("local Ollama model identifier is invalid")
    tag = model.rsplit(":", 1)[-1].casefold()
    if "cloud" in tag:
        raise ValueError("Ollama cloud models are prohibited on local-only paths")


def _sanitize_text(value: str, redactions: tuple[str, ...]) -> str:
    sanitized = value
    for secret in redactions:
        replacement = "<HOME>" if secret == str(Path.home()) else "<REDACTED>"
        sanitized = sanitized.replace(secret, replacement)
    return sanitized


def _bytes(value: bytes | str | None) -> bytes:
    if value is None:
        return b""
    return value.encode("utf-8") if isinstance(value, str) else value


def _now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
