# Green fixture: idiomatic evidence-preserving Python. Must produce zero findings from
# both fragments — this file is the profile's false-positive guard, so every construct
# here is one an agent should be free to write without a warning.
#
# Deliberately no third-party imports. A pydantic model would be the natural boundary
# parser, but mypy reports `import-not-found` for a package the self-test does not
# install, which would show up as a green-fixture finding. The dataclass below parses
# at the boundary the same way: untrusted mapping in, named domain type out.
from collections.abc import Mapping
from dataclasses import dataclass
from typing import NewType, cast

UserId = NewType("UserId", str)


@dataclass(frozen=True)
class User:
    id: UserId
    display_name: str


def parse_user(payload: Mapping[str, object]) -> User:
    """Parse an untrusted payload at its boundary into a named domain type."""
    raw_id = payload["id"]
    raw_name = payload["display_name"]
    if not isinstance(raw_id, str) or not isinstance(raw_name, str):
        raise ValueError("user payload fields must be strings")
    return User(id=UserId(raw_id), display_name=raw_name)


def slugify(value: str) -> str:
    return "-".join(part for part in value.lower().split() if part)


def user_slug(user: User) -> UserId:
    # SAFETY: slugify emits only lowercase words joined by hyphens, which satisfies the
    # UserId contract, and the result is never fed back into an id lookup.
    return cast(UserId, slugify(user.display_name))


def _total(values: list[float]) -> float:
    return sum(values)


def report_total(counts: list[int]) -> float:
    # `list` is invariant, so mypy rejects list[int] where list[float] is declared;
    # every int is a valid float at runtime and _total only reads the list.
    return _total(counts)  # type: ignore[arg-type]
