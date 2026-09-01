#!/usr/bin/env -S python3 -S
from __future__ import annotations

import os
import sys

LIB = os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib")
if LIB not in sys.path:
    sys.path.insert(0, LIB)

if len(sys.argv) > 1:
    _first = sys.argv[1]
    if (
        _first in {"--json", "--month", "--lane"}
        or _first.startswith("--month=")
        or _first.startswith("--lane=")
    ):
        # Keep the documented root query shorthand on the same import-light
        # path as the explicit ``query`` subcommand.
        sys.argv.insert(1, "query")

if len(sys.argv) > 1 and sys.argv[1] == "query":
    _MISSING = object()

    class _FastField:
        __slots__ = ("default", "default_factory", "kw_only")

        def __init__(
            self,
            *,
            default=_MISSING,
            default_factory=_MISSING,
            kw_only=False,
        ):
            self.default = default
            self.default_factory = default_factory
            self.kw_only = kw_only

    def _fast_field(
        *,
        default=_MISSING,
        default_factory=_MISSING,
        kw_only=False,
        **_ignored,
    ):
        return _FastField(
            default=default,
            default_factory=default_factory,
            kw_only=kw_only,
        )

    def _fast_dataclass(cls=None, **options):
        def decorate(target):
            class_kw_only = options.get("kw_only", False)
            fields = []
            for name in target.__annotations__:
                configured = target.__dict__.get(name, _MISSING)
                if isinstance(configured, _FastField):
                    default = configured.default
                    default_factory = configured.default_factory
                    kw_only = class_kw_only or configured.kw_only
                else:
                    default = configured
                    default_factory = _MISSING
                    kw_only = class_kw_only
                fields.append((name, default, default_factory, kw_only))

            def initialize(self, *args, **kwargs):
                positional = [item for item in fields if not item[3]]
                if len(args) > len(positional):
                    raise TypeError("too many positional arguments")
                values = dict(zip((item[0] for item in positional), args))
                for name, default, default_factory, _ in fields:
                    if name in kwargs:
                        if name in values:
                            raise TypeError(f"multiple values for {name}")
                        value = kwargs.pop(name)
                    elif name in values:
                        value = values[name]
                    elif default_factory is not _MISSING:
                        value = default_factory()
                    elif default is not _MISSING:
                        value = default
                    else:
                        raise TypeError(f"missing required argument: {name}")
                    object.__setattr__(self, name, value)
                if kwargs:
                    unexpected = next(iter(kwargs))
                    raise TypeError(f"unexpected argument: {unexpected}")
                post_init = getattr(self, "__post_init__", None)
                if post_init is not None:
                    post_init()

            def equal(self, other):
                return type(other) is target and all(
                    getattr(self, item[0]) == getattr(other, item[0])
                    for item in fields
                )

            target.__init__ = initialize
            target.__eq__ = equal
            target.__fast_dataclass_fields__ = tuple(item[0] for item in fields)
            return target

        return decorate if cls is None else decorate(cls)

    def _fast_replace(value, **changes):
        fields = getattr(value, "__fast_dataclass_fields__", None)
        if fields is None:
            values = dict(value.__dict__)
        else:
            values = {
                name: getattr(value, name)
                for name in fields
            }
        values.update(changes)
        return type(value)(**values)

    class _FastDataclasses:
        dataclass = staticmethod(_fast_dataclass)
        field = staticmethod(_fast_field)
        replace = staticmethod(_fast_replace)

    from collections.abc import Iterable, Mapping, Sequence

    class _FastTyping:
        TYPE_CHECKING = False
        Any = object
        Final = object
        Iterable = Iterable
        Mapping = Mapping
        Sequence = Sequence

    _saved_dataclasses = sys.modules.get("dataclasses")
    _saved_typing = sys.modules.get("typing")
    sys.modules["dataclasses"] = _FastDataclasses()
    sys.modules["typing"] = _FastTyping()
    try:
        from usage_federation.query import fast_query_main
    finally:
        if _saved_dataclasses is None:
            del sys.modules["dataclasses"]
        else:
            sys.modules["dataclasses"] = _saved_dataclasses
        if _saved_typing is None:
            del sys.modules["typing"]
        else:
            sys.modules["typing"] = _saved_typing
    _query_exit = fast_query_main(
        sys.argv[1:],
        release_root=os.path.dirname(os.path.dirname(os.path.realpath(__file__))),
    )
    if _query_exit is not None:
        raise SystemExit(_query_exit)

from usage_federation.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
