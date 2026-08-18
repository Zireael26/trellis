# Red fixture: every construct here must produce at least one finding.
# One pattern per definition, so inverting a rule breaks exactly one expectation.
# The comment above each definition names the rule and the fragment that owns it.
from dataclasses import dataclass
from typing import Any, cast
from unittest import mock


@dataclass
class Widget:
    id: str


# ruff ANN401 (x2): escape-hatch type on both the argument and the return contract.
def coerce(payload: Any) -> Any:
    return payload


# mypy no-untyped-def: no contract to check, which also leaves ANN401 nothing to read.
def widen(payload):
    return payload


# mypy no-any-return: unparsed boundary data laundered into a typed contract. The
# nested `dict[str, Any]` is itself invisible to both fragments (README § Known gaps).
def read_title(payload: dict[str, Any]) -> str:
    return payload["title"]


# Pattern layer, py-unjustified-cast: an assertion with no stated invariant. Neither
# ruff nor mypy expresses this one; the tripwire pattern set owns it.
def as_widget(payload: dict[str, str]) -> Widget:
    return cast(Widget, payload)


# mypy ignore-without-code: a suppression that names nothing, so it also swallows every
# error the line grows later.
def count(raw: str) -> int:
    return int(raw)  # type: ignore


# ruff PGH004: the same failure in the lint suppression channel.
def strip(raw: str) -> str:
    return raw.strip()  # noqa


# Pattern layer, py-module-patch: patches a dotted module path instead of a real seam.
def patch_client() -> None:
    mock.patch("app.client.fetch")
