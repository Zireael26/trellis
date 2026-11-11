#!/usr/bin/env python3
"""Dependency-free validation of the JSON Schema vocabulary used by this tool."""
import argparse
import json
import math
import re
import sys
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True
SCHEMAS = Path(__file__).resolve().parent


class EvidenceError(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("duplicate JSON key: " + key)
        result[key] = value
    return result


def loads(text):
    def invalid(value):
        raise EvidenceError("non-finite JSON number: " + value)
    def finite_float(value):
        number = float(value)
        if not math.isfinite(number):
            raise EvidenceError("non-finite JSON number: " + value)
        return number
    return json.loads(text, object_pairs_hook=unique_object, parse_constant=invalid, parse_float=finite_float)


def load(path):
    return loads(Path(path).read_text(encoding="utf-8"))


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def validate(value, definition, root=None, location="$"):
    root = definition if root is None else root
    supported = {"$schema", "$id", "$defs", "$ref", "title", "description", "type", "const", "enum",
                 "required", "properties", "additionalProperties", "items", "minItems", "uniqueItems",
                 "minLength", "pattern", "minimum", "maximum", "oneOf", "anyOf", "format"}
    unknown = set(definition) - supported
    if unknown:
        raise EvidenceError("unsupported schema vocabulary: " + ",".join(sorted(unknown)))
    if "$ref" in definition:
        reference = definition["$ref"]
        if not reference.startswith("#/"):
            raise EvidenceError("only local schema references are supported")
        target = root
        for component in reference[2:].split("/"):
            target = target[component.replace("~1", "/").replace("~0", "~")]
        validate(value, target, root, location)
    for union in ("oneOf", "anyOf"):
        if union in definition:
            accepted = 0
            for branch in definition[union]:
                try:
                    validate(value, branch, root, location)
                    accepted += 1
                except EvidenceError:
                    pass
            if (union == "oneOf" and accepted != 1) or (union == "anyOf" and accepted == 0):
                raise EvidenceError(location + ": no unique matching " + union)
    expected = definition.get("type")
    predicates = {"object": lambda x: type(x) is dict, "array": lambda x: type(x) is list,
                  "string": lambda x: type(x) is str, "integer": lambda x: type(x) is int,
                  "number": lambda x: type(x) is int or (type(x) is float and math.isfinite(x)),
                  "boolean": lambda x: type(x) is bool, "null": lambda x: x is None}
    if expected is not None:
        types = expected if isinstance(expected, list) else [expected]
        if not any(predicates[kind](value) for kind in types):
            raise EvidenceError(location + ": expected " + str(expected))
    if "const" in definition and canonical(value) != canonical(definition["const"]):
        raise EvidenceError(location + ": incorrect constant")
    if "enum" in definition and canonical(value) not in [canonical(item) for item in definition["enum"]]:
        raise EvidenceError(location + ": outside closed vocabulary")
    if type(value) is dict:
        missing = set(definition.get("required", [])) - set(value)
        if missing:
            raise EvidenceError(location + ": missing " + ",".join(sorted(missing)))
        properties = definition.get("properties", {})
        for key, item in value.items():
            rule = properties.get(key, definition.get("additionalProperties", True))
            if rule is False:
                raise EvidenceError(location + ": unknown field " + key)
            if type(rule) is dict:
                validate(item, rule, root, location + "." + key)
    if type(value) is list:
        if len(value) < definition.get("minItems", 0):
            raise EvidenceError(location + ": too few items")
        if definition.get("uniqueItems") and len({canonical(item) for item in value}) != len(value):
            raise EvidenceError(location + ": duplicate item")
        if "items" in definition:
            for index, item in enumerate(value):
                validate(item, definition["items"], root, location + "[" + str(index) + "]")
    if type(value) is str:
        if len(value) < definition.get("minLength", 0) or ("pattern" in definition and re.search(definition["pattern"], value) is None):
            raise EvidenceError(location + ": invalid string")
        if definition.get("format") == "date-time":
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError("timezone required")
            except ValueError as error:
                raise EvidenceError(location + ": invalid timestamp") from error
    if type(value) in (int, float):
        if value < definition.get("minimum", -math.inf) or value > definition.get("maximum", math.inf):
            raise EvidenceError(location + ": number out of range")


def validate_named(name, document):
    if name not in ("receipt", "run-record", "requirements"):
        raise EvidenceError("unknown schema: " + name)
    validate(document, load(SCHEMAS / (name + ".schema.json")))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema", required=True, choices=("receipt", "run-record", "requirements"))
    parser.add_argument("document", type=Path)
    args = parser.parse_args(argv)
    try:
        validate_named(args.schema, load(args.document))
    except (EvidenceError, OSError, ValueError, KeyError) as error:
        print("qualification schema: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
