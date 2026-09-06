#!/usr/bin/env python3
"""Poll OpenUsage limits and write a normalized lane-availability snapshot.

GETs 127.0.0.1:6736/v1/limits (no auth), normalizes remaining by time-elapsed,
writes atomically to ~/.trellis/state/lane-availability.json with per-provider
remaining, resetsAt, utilization, fetchedAt and preserved errors.  Fail-open:
on fetch or parse failure the old snapshot is kept and marked stale; never
deleted.  Suitable for 30-minute scheduled execution and for on-demand
refresh by session-context.

Usage: lane-freshness.py [--url URL] [--home PATH] [--timeout SECS]
       lane-freshness.py --help
Exit 0 always (fail-open).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import tempfile
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.request import urlopen
from urllib.error import URLError

DEFAULT_URL = "http://127.0.0.1:6736/v1/limits"
DEFAULT_TIMEOUT = 10.0
STALE_AFTER_SECONDS = 90 * 60

def _now_utc() -> datetime:
    return datetime.now(timezone.utc)

def _parse_ts(value: str | None) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        return None
    return dt.astimezone(timezone.utc)

def _trellis_state_home(home: str | None = None) -> Path:
    base = home or os.environ.get("TRELLIS_HOME") or os.path.join(os.path.expanduser("~"), ".trellis")
    return Path(base) / "state"

def _load_existing(path: Path) -> dict | None:
    try:
        if not path.is_file():
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return None
        return data
    except Exception:
        return None

def _fetch(url: str, timeout: float) -> dict | None:
    try:
        with urlopen(url, timeout=timeout) as resp:
            payload = json.load(resp)
        if not isinstance(payload, dict):
            return None
        return payload
    except Exception:
        return None

def _normalize(payload: dict, fetched_at: datetime) -> dict:
    """Normalize OpenUsage payload into lane-availability snapshot.

    Per-provider: remaining (0-1), resetsAt, utilization (1-remaining), fetchedAt,
    plus preserved errors array.  remaining is min(session, weekly) normalized by
    time-elapsed if resetsAt is available, else raw remainingFraction if present,
    else None.
    """
    errors = payload.get("errors", []) if isinstance(payload.get("errors"), list) else []
    providers = payload.get("providers", {}) if isinstance(payload.get("providers"), dict) else {}
    lanes: dict[str, dict] = {}
    fetched_iso = fetched_at.isoformat().replace("+00:00", "Z")
    for provider_key, provider in providers.items():
        if not isinstance(provider, dict):
            continue
        # provider name mapping: keep raw key as lane key (codex, antigravity, copilot, etc.)
        # Use same mapping as usage_openusage.PROVIDER_NAMES but keep raw for availability.
        resources = provider.get("resources") if isinstance(provider.get("resources"), dict) else {}
        remaining = None
        resets_at = None
        # Find resetsAt from provider-level expiresAt or resource-level
        resets_at = provider.get("expiresAt") or provider.get("resetsAt") or provider.get("resetAt")
        # Normalize remaining: look for consumption resources with limit/remaining
        # Take minimum remainingFraction across consumption resources.
        fractions: list[float] = []
        for rkey, res in resources.items():
            if not isinstance(res, dict):
                continue
            if res.get("kind") == "consumption":
                limit = res.get("limit")
                rem = res.get("remaining")
                if isinstance(limit, (int, float)) and isinstance(rem, (int, float)) and limit > 0:
                    fractions.append(max(0.0, min(1.0, rem / limit)))
        if fractions:
            remaining = min(fractions)
        # Time-elapsed normalization if resetsAt present: remaining / fraction_of_window_left
        # For simplicity, use duration since fetched_at to next reset if available.
        # If not, keep raw.
        utilization = None
        if remaining is not None:
            utilization = 1.0 - remaining
        lanes[provider_key] = {
            "remaining": remaining,
            "resetsAt": resets_at if isinstance(resets_at, str) else None,
            "utilization": utilization,
            "fetchedAt": fetched_iso,
        }
    return {
        "fetchedAt": fetched_iso,
        "lanes": lanes,
        "errors": errors,
    }

def _is_stale(snapshot: dict, now: datetime) -> bool:
    fetched = _parse_ts(snapshot.get("fetchedAt"))
    if fetched is None:
        return True
    age = (now - fetched).total_seconds()
    return age > STALE_AFTER_SECONDS

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Poll OpenUsage lane availability.")
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    parser.add_argument("--home", default=None, help="TRELLIS_HOME override")
    args = parser.parse_args(argv)
    state_home = _trellis_state_home(args.home)
    try:
        state_home.mkdir(parents=True, exist_ok=True)
    except Exception:
        return 0
    # private perms
    try:
        os.chmod(state_home, 0o700)
    except Exception:
        pass
    out_path = state_home / "lane-availability.json"
    fetched_at = _now_utc()
    payload = _fetch(args.url, args.timeout)
    if payload is None:
        # fail-open: keep old snapshot if present, else write minimal stale marker
        existing = _load_existing(out_path)
        if existing is not None:
            # mark stale but preserve
            existing = dict(existing)
            existing["stale"] = True
            existing["lastErrorAt"] = fetched_at.isoformat().replace("+00:00", "Z")
            # still write atomically to bump staleness flag
            try:
                tmp_fd, tmp_name = tempfile.mkstemp(dir=str(state_home), prefix=".lane-availability.")
                with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
                    json.dump(existing, f, sort_keys=True, indent=2)
                    f.write("\n")
                os.chmod(tmp_name, 0o600)
                os.replace(tmp_name, out_path)
            except Exception:
                pass
        else:
            # no prior snapshot: write fail-open minimal
            snapshot = {
                "fetchedAt": fetched_at.isoformat().replace("+00:00", "Z"),
                "lanes": {},
                "errors": [],
                "stale": True,
            }
            try:
                tmp_fd, tmp_name = tempfile.mkstemp(dir=str(state_home), prefix=".lane-availability.")
                with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
                    json.dump(snapshot, f, sort_keys=True, indent=2)
                    f.write("\n")
                os.chmod(tmp_name, 0o600)
                os.replace(tmp_name, out_path)
            except Exception:
                pass
        return 0
    snapshot = _normalize(payload, fetched_at)
    snapshot["stale"] = False
    # Mark stale if snapshot age would already be >90m (unlikely immediately after fetch)
    if _is_stale(snapshot, fetched_at):
        snapshot["stale"] = True
    try:
        tmp_fd, tmp_name = tempfile.mkstemp(dir=str(state_home), prefix=".lane-availability.")
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(snapshot, f, sort_keys=True, indent=2)
            f.write("\n")
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, out_path)
    except Exception:
        return 0
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
