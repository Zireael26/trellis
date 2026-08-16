#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

LIB = Path(__file__).resolve().parent / "lib"
if str(LIB) not in sys.path:
    sys.path.insert(0, str(LIB))

from aeo_gate.cli import main  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main())
