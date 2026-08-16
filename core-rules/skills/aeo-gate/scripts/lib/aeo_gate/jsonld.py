from __future__ import annotations

import json
from collections.abc import Iterable, Iterator
from typing import Any

ABSENT = "absent"
VACUOUS = "vacuous"
POPULATED = "populated"


def parse_jsonld_blocks(blocks: Iterable[str]) -> tuple[list[Any], list[str]]:
    documents: list[Any] = []
    errors: list[str] = []
    for index, block in enumerate(blocks):
        try:
            documents.append(json.loads(block))
        except (TypeError, json.JSONDecodeError) as exc:
            errors.append(f"block {index}: {exc}")
    return documents, errors


def walk(
    value: Any, path: tuple[str, ...] = ()
) -> Iterator[tuple[tuple[str, ...], Any]]:
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, (*path, str(key)))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, (*path, str(index)))


def values_for_key(documents: Iterable[Any], key: str) -> list[Any]:
    wanted = key.casefold()
    return [
        value
        for document in documents
        for path, value in walk(document)
        if path and path[-1].casefold() == wanted
    ]


def classify_key(documents: Iterable[Any], key: str) -> tuple[str, list[Any]]:
    values = values_for_key(documents, key)
    if not values:
        return ABSENT, []
    if all(is_vacuous(value) for value in values):
        return VACUOUS, values
    return POPULATED, values


def is_vacuous(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str):
        return not value.strip()
    if isinstance(value, (list, tuple, set)):
        return not value or all(is_vacuous(item) for item in value)
    if isinstance(value, dict):
        return not value or all(is_vacuous(item) for item in value.values())
    return False
