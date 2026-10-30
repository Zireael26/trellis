"""Targeted regressions for the serialized usage-store open path."""

from __future__ import annotations

import fcntl
import os
import sqlite3
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from usage_federation import store as store_module


@pytest.fixture
def home(tmp_path):
    with store_module.UsageStore.open(tmp_path):
        pass
    return tmp_path


def set_clean_minute(home, minute):
    with sqlite3.connect(home / "usage/usage.sqlite3") as connection:
        connection.execute(f"PRAGMA user_version={minute}")


def clean_minute(home):
    with sqlite3.connect(home / "usage/usage.sqlite3") as connection:
        return connection.execute("PRAGMA user_version").fetchone()[0]


def trace_opens(monkeypatch):
    statements = []
    original = sqlite3.connect

    def connect(*args, **kwargs):
        connection = original(*args, **kwargs)
        # Exclude the in-memory expected-schema builder from open-path receipts.
        if str(args[0]) != ":memory:":
            connection.set_trace_callback(statements.append)
        return connection

    monkeypatch.setattr(store_module.sqlite3, "connect", connect)
    return statements


def scans(statements):
    return [s.lower() for s in statements if s.lower().startswith(
        ("pragma foreign_key_check", "pragma quick_check", "pragma integrity_check")
    )]


def test_recent_clean_open_skips_scans_but_checks_shape_and_version(home, monkeypatch):
    minute = int(time.time() // 60)
    set_clean_minute(home, minute)
    statements = trace_opens(monkeypatch)
    for _ in range(2):
        with store_module.UsageStore.open(home):
            pass
    assert scans(statements) == []
    assert sum("SELECT version, applied_at" in s for s in statements) >= 2
    assert sum(s.startswith("PRAGMA table_xinfo") for s in statements) >= 2
    assert clean_minute(home) == minute


@pytest.mark.parametrize("age_minutes", [None, 1442, -60])
def test_missing_expired_or_future_stamp_scans_and_persists(home, monkeypatch, age_minutes):
    now_minute = int(time.time() // 60)
    set_clean_minute(home, 0 if age_minutes is None else now_minute - age_minutes)
    statements = trace_opens(monkeypatch)
    with store_module.UsageStore.open(home):
        pass
    assert "pragma foreign_key_check" in scans(statements)
    assert "pragma quick_check(1)" in scans(statements)
    assert now_minute <= clean_minute(home) <= int(time.time() // 60)
    statements.clear()
    with store_module.UsageStore.open(home):
        pass
    assert scans(statements) == []


@pytest.mark.parametrize("failure", ["foreign", "quick"])
def test_failed_scan_refuses_without_stamping(home, monkeypatch, failure):
    set_clean_minute(home, 0)
    original = sqlite3.connect

    class BrokenScan(sqlite3.Connection):
        def execute(self, sql, *args, **kwargs):
            if sql == "PRAGMA foreign_key_check" and failure == "foreign":
                return super().execute("SELECT 'bad', 1, 'parent', 0")
            if sql == "PRAGMA quick_check(1)" and failure == "quick":
                return super().execute("SELECT 'damaged page'")
            return super().execute(sql, *args, **kwargs)

    def connect(*args, **kwargs):
        return original(*args, **kwargs, factory=BrokenScan)

    monkeypatch.setattr(store_module.sqlite3, "connect", connect)
    with pytest.raises(store_module.CorruptStoreError, match="foreign_key_check|quick_check"):
        store_module.UsageStore.open(home)
    assert clean_minute(home) == 0


@pytest.mark.parametrize("existing_version", [0, 4])
def test_create_and_migration_force_scans_even_with_recent_stamp(tmp_path, monkeypatch, existing_version):
    if existing_version:
        usage = tmp_path / "usage"
        usage.mkdir(mode=0o700)
        with sqlite3.connect(usage / "usage.sqlite3", isolation_level=None) as connection:
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("BEGIN IMMEDIATE")
            for version in range(1, existing_version + 1):
                for statement in store_module._MIGRATIONS[version]:
                    connection.execute(statement)
                connection.execute(
                    "INSERT INTO schema_version VALUES (?, '2026-01-01T00:00:00Z')", (version,)
                )
            connection.execute(f"PRAGMA user_version={int(time.time() // 60)}")
            connection.execute("COMMIT")
        (usage / "usage.sqlite3").chmod(0o600)
    statements = trace_opens(monkeypatch)
    with store_module.UsageStore.open(tmp_path):
        pass
    assert "pragma foreign_key_check" in scans(statements)
    assert "pragma quick_check(1)" in scans(statements)
    assert clean_minute(tmp_path) > 0


def test_recent_stamp_does_not_hide_changed_schema(home):
    set_clean_minute(home, int(time.time() // 60))
    with sqlite3.connect(home / "usage/usage.sqlite3") as connection:
        connection.execute("DROP INDEX usage_events_provider_time")
    with pytest.raises(store_module.CorruptStoreError, match="schema manifest"):
        store_module.UsageStore.open(home)


def test_recent_stamp_does_not_hide_future_schema_version(home):
    set_clean_minute(home, int(time.time() // 60))
    with sqlite3.connect(home / "usage/usage.sqlite3") as connection:
        connection.execute("INSERT INTO schema_version VALUES (6, 'future')")
    with pytest.raises(store_module.UnsupportedSchemaVersionError):
        store_module.UsageStore.open(home)


@pytest.mark.parametrize("elapsed_seconds, expect_scan", [(0, False), (86400, False), (86459, False), (86460, True)])
def test_daily_scan_boundary(home, monkeypatch, elapsed_seconds, expect_scan):
    minute = int(time.time() // 60)
    set_clean_minute(home, minute)
    monkeypatch.setattr(store_module.time, "time", lambda: minute * 60 + elapsed_seconds)
    statements = trace_opens(monkeypatch)
    with store_module.UsageStore.open(home):
        pass
    assert bool(scans(statements)) is expect_scan


def test_real_quick_check_failure_does_not_stamp(home):
    set_clean_minute(home, 0)
    with sqlite3.connect(home / "usage/usage.sqlite3") as connection:
        connection.execute("PRAGMA ignore_check_constraints=ON")
        connection.execute("INSERT INTO source_roots(source_id) VALUES ('')")
    with pytest.raises(store_module.CorruptStoreError, match="quick_check failed"):
        store_module.UsageStore.open(home)
    assert clean_minute(home) == 0


def test_recent_clean_open_still_obeys_directory_lock(home):
    descriptor = os.open(home / "usage", os.O_RDONLY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with pytest.raises(store_module.StoreBusyError, match="serialized open"):
            store_module.UsageStore.open(home, busy_timeout_ms=0)
    finally:
        os.close(descriptor)
    with store_module.UsageStore.open(home, busy_timeout_ms=0):
        pass


def test_read_only_open_never_scans_or_stamps(home, monkeypatch):
    set_clean_minute(home, 0)
    statements = trace_opens(monkeypatch)
    with store_module.UsageStore.open_query(home):
        pass
    assert scans(statements) == []
    assert clean_minute(home) == 0
