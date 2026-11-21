import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
base = {
    "schema_version": 1,
    "source_root": "/opt/src",
    "release_remote": "fixture://r",
    "active_cli_release": "1.2.3",
    "default_fleet": "personal",
    "fleets": {"personal": {"discovery_roots": ["/p"]}},
}
cases = {}


def raw(o):
    return json.dumps(o, separators=(",", ":")).encode()


B = raw(base)


def put(name, data):
    cases[name] = data


def sub(field, literal_bytes, obj=None):
    o = dict(obj or base)
    o[field] = "@@V@@"
    return raw(o).replace(b'"@@V@@"', literal_bytes)


put("valid", B)
put("valid-pretty", json.dumps(base, indent=2).encode() + b"\n")
schema_lits = [
    "1",
    "1.0",
    "10e-1",
    "1e0",
    "1E0",
    "1e+0",
    "1e-0",
    "0.1e1",
    ".1e1",
    "1.",
    "+1",
    "01",
    "001",
    "1.00",
    "100e-2",
    "1.0000000000000000001",
    "0.99999999999999999999",
    "-1",
    "-0",
    "0",
    "2",
    "1e1",
    "1.e0",
    "01.0",
    "+01.",
    "NaN",
    "nan",
    "-nan",
    "Infinity",
    "inf",
    "-inf",
    "sNaN",
    "NaN1",
    "nan1",
    "0x1",
    "1e",
    "e1",
    '"1"',
    "true",
    "null",
    "1.0e00000000000000000000",
    "10000000000000000000000e-22",
    "1." + "0" * 400,
    "1" + "0" * 400 + "e-400",
    "0." + "0" * 400 + "1e401",
    "1e-00",
    "+1e0",
    "+.1e1",
    "1E-0",
]
for i, lit in enumerate(schema_lits):
    put(f"schema-{i:02d}-{lit[:20]}", sub("schema_version", lit.encode()))
proj_lits = [
    "NaN",
    "nan",
    "-nan",
    "+nan",
    "sNaN",
    "-sNaN",
    "NaN1",
    "NaN0",
    "nan1",
    "Infinity",
    "-Infinity",
    "+Infinity",
    "inf",
    "INF",
    "-inf",
    "Inf",
    "infinit",
    "infinityy",
    "01",
    "+1",
    ".5",
    "1.",
    "-.5",
    "-01",
    "1e",
    "1e+",
    ".",
    "+",
    "-",
    "1.5.5",
    "0x10",
    "1_0",
    "tru",
    "nul",
    "null",
    "true",
    "1e1000",
    "-1e1000",
    "1e-1000",
    '"\\q"',
    '"\\\'"',
    '"\\u12"',
    '"\\uZZZZ"',
    '"\\ud800"',
    '"\\ud800x"',
    '"\\ud800\\u0041"',
    '"\\udc00"',
    '"\\ud800\\udc00"',
    '"\\udbff\\udfff"',
    '"\\ud800\\ud800"',
    '"\\udc00\\ud800"',
    '"\\u0000"',
    "'x'",
    "[1,]",
    '{"a":1,}',
    "[,1]",
    "[1 2]",
    '{"a" 1}',
    '{"a":}',
    "{1:2}",
    "[] []",
]
for i, lit in enumerate(proj_lits):
    put(f"proj-{i:02d}-{lit[:16]}", sub("projects", lit.encode()))
# R2-1: Perl strict UTF-8 refuses these well-formed Unicode noncharacters.
# Apex accepts this named fail-closed difference from jq.
for cp in (0xFFFE, 0xFFFF, 0xFDD0, 0x10FFFF):
    put(f"noncharacter-{cp:x}", sub("projects", b'"' + chr(cp).encode("utf-8") + b'"'))
# raw bytes inside a projects string
for i, bs in enumerate(
    [
        b"\x01",
        b"\t",
        b"\n",
        b"\r",
        b"\x7f",
        b"\x1f",
        b"\xff",
        b"\xc0\x80",
        b"\xed\xa0\x80",
        b"\xf0\x9f",
        b"\xf4\x90\x80\x80",
        b"\xf8\x88\x80\x80\x80",
        b"\xe2\x80\xa8",
        b"\xc2\xa0",
    ]
):
    put(f"projraw-{i:02d}", sub("projects", b'"x' + bs + b'y"'))
# U+FFFD counting via discovery_roots uniqueness
bad = [
    b"\xff",
    b"\xff\xff",
    b"\xf0\x9f",
    b"\xc0\x80",
    b"\xed\xa0\x80",
    b"\xf4\x90\x80\x80",
    b"\xf8\x88\x80\x80\x80",
    b"\xe2\x82",
    b"\x80",
    b"\xef\xbf\xbd",
    b"\\udc00",
    b"\\ufffd",
    b"\xe0\x80\x80",
    b"\xf0\x80\x80\x80",
    b"\xfe",
]
for i, a in enumerate(bad):
    for j, b in enumerate(bad):
        if j <= i:
            continue
        roots = b'["/a' + a + b'","/a' + b + b'"]'
        o = dict(base)
        o["fleets"] = "@@F@@"
        put(
            f"fffd-{i:02d}-{j:02d}",
            raw(o).replace(
                b'"@@F@@"', b'{"personal":{"discovery_roots":' + roots + b"}}"
            ),
        )
# Byte-oriented normalization must still compare decoded Unicode root values.
# Raw UTF8 and its JSON escape denote the same path, not two distinct roots.
for name, roots in [
    ('unicode-roots-mixed-duplicate', b'["/p/\xc3\xa9","/p/\\u00e9"]'),
    ('unicode-roots-pair-duplicate', b'["/p/\xf0\x9f\x98\x80","/p/\\ud83d\\ude00"]'),
    ('unicode-roots-distinct', b'["/p/\xc3\xa9","/p/\xc3\xa8"]'),
]:
    put(name, sub('fleets', b'{"personal":{"discovery_roots":' + roots + b'}}'))
# whitespace classes between tokens
for i, ws in enumerate(
    [b"\x0c", b"\x0b", b"\xc2\xa0", b"\xe2\x80\xa8", b"\xc2\x85", b"\r", b"\t", b" \n "]
):
    put(f"ws-{i}", B.replace(b'"schema_version":1', b'"schema_version":' + ws + b"1"))
    put(f"wslead-{i}", ws + B)
# BOM
bom = b"\xef\xbb\xbf"
put("bom", bom + B)
put("bom2", bom + bom + B)
put("bom-after-ws", b" " + bom + B)
put("bom-mid", B[:1] + bom + B[1:])
put("bom-tail", B + bom)
# NUL
for name, data in {
    "nul-eof": B + b"\0",
    "nul-nl": B + b"\0\n",
    "nul-junk-nl": B + b"\0junk\n",
    "nl-nul": B + b"\n\0",
    "nl-nul-nl": B + b"\n\0\n",
    "nul-lead": b"\0" + B,
    "nul-in-string-nl": sub("projects", b'"a\0b"') + b"\n",
    "nul-in-string-eof": sub("projects", b'"a\0b"'),
    "pretty-nul-mid": json.dumps(base, indent=2).encode().replace(b'"/p"', b'"/p"\0')
    + b"\n",
    "nul-schema2-nl": B + b"\0" + raw({**base, "schema_version": 2}) + b"\n",
    "nul-x-eof": B + b"\0}}}",
}.items():
    put(name, data)
# multi-document
inv = raw({**base, "schema_version": 2})
for name, data in {
    "two-valid": B + B,
    "two-valid-nl": B + b"\n" + B,
    "inv-then-valid": inv + b"\n" + B,
    "valid-then-inv": B + b"\n" + inv,
    "valid-then-1": B + b" 1",
    "one-then-valid": b"1 " + B,
    "valid-then-true": B + b" true",
    "arr-then-valid": b"[] " + B,
    "valid-then-str": B + b' "x"',
    "valid-then-garbage": B + b" junk",
    "valid-then-open": B + b" {",
}.items():
    put(name, data)
# comments
put("hash-comment-tail", B + b" # c")
put("hash-comment-lead", b"# c\n" + B)
put("c-comment", b"/* c */" + B)
put("slash-comment", B + b"// c")
# depth
for n in range(250, 258):
    put(f"deep-arr-{n}", sub("projects", b"[" * n + b"]" * n))
    put(f"deep-arr-null-{n}", sub("projects", b"[" * n + b"null" + b"]" * n))
    put(f"deep-arr-obj-{n}", sub("projects", b"[" * n + b"{}" + b"]" * n))
    put(f"deep-arr-objkv-{n}", sub("projects", b"[" * n + b'{"a":1}' + b"]" * n))
for n in range(122, 132):
    put(f"deep-obj-{n}", sub("projects", b'{"a":' * n + b"1" + b"}" * n))
    put(f"deep-obj-arr-{n}", sub("projects", b'{"a":' * n + b"[]" + b"}" * n))
    put(f"deep-objarr-{n}", sub("projects", b'{"a":[' * n + b"1" + b"]}" * n))
    put(f"deep-obj-empty-{n}", sub("projects", b'{"a":' * n + b"{}" + b"}" * n))
# R2-2: the last schema_version member controls, including string values.
put("dup-1-then-str", B.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":"x"'))
put("dup-str-then-1", B.replace(b'"schema_version":1', b'"schema_version":"x","schema_version":1'))
# duplicate keys
put(
    "dup-schema-2-1",
    B.replace(b'"schema_version":1', b'"schema_version":2,"schema_version":1'),
)
put(
    "dup-schema-1-2",
    B.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":2'),
)
put(
    "dup-escaped-key",
    B.replace(b'"schema_version":1', b'"schema_version":1,"schema\\u005fversion":2'),
)
put("dup-fleets", B[:-1] + b',"fleets":{}}')
put("dup-default-fleet", B[:-1] + b',"default_fleet":"other"}')
put(
    "dup-root-in-fleet",
    B.replace(
        b'{"discovery_roots":["/p"]}',
        b'{"discovery_roots":["/p"],"discovery_roots":[]}',
    ),
)
# type and value checks
vals = {
    "source_root": [
        "5",
        "1e5",
        "[]",
        '"/"',
        '"//x"',
        '"/a/./b"',
        '"/a/../b"',
        '"/a/b/"',
        '"/a/b/."',
        '"/."',
        '"/.."',
        '"/..."',
        '"/a\\tb"',
        '"/a\\u0000b"',
        '"/a\\u000bb"',
        '"/a\\u0085"',
        '"/a//b"',
        '"/\\u00e9"',
        '"x/a"',
        '""',
        '"/a\\nb"',
        '"/a\\rb"',
        '"/.a"',
        '"/a."',
        '"/a/.."',
        '"/./"',
    ],
    "release_remote": [
        "5",
        '""',
        '" "',
        '"\\u000b"',
        '"\\t"',
        "null",
        '"x\\u0000"',
        '["x"]',
    ],
    "active_cli_release": [
        "1.2",
        '"1.2.3"',
        '"1.2.3-"',
        '"1.2.3+"',
        '"01.2.3"',
        '"1.2.3-a_b"',
        '"1.2.3-a.b+c.d"',
        '"1.2.3\\n"',
        '"\\uff11.2.3"',
        '"1.2.3 "',
        '"v1.2.3"',
        '"1.2.3-\\u00e9"',
        '"1.2.3+x+y"',
        '"1.2.3-x-y"',
    ],
    "default_fleet": [
        "5",
        '"Personal"',
        '"other"',
        '""',
        '"personal\\n"',
        '"a"',
        '"-a"',
    ],
    "$schema": ["5", '""', '"x"', '"\\t"', "null", '"\\u0001"'],
    "heavy_slots": ["0", '"x"', "{}", "1e999"],
    "process_gate_slots": [
        "1", "2", "0", "-1", "3", '"2"', "true", "null", "[]", "{}",
        "2.0", "2e0", "2.0000000000000000001", "1e400",
    ],
    "process_gate_slot": ["2"],  # The machine object stays closed.
    "projects": ['{"x":[1,2]}', "null"],
    "surprise": ["1"],
}
for f, ls in vals.items():
    for i, lit in enumerate(ls):
        put(f"val-{f.strip('$')}-{i:02d}", sub(f, lit.encode()))
fleet_vals = [
    "{}",
    '{"personal":null}',
    '{"personal":{"discovery_roots":[]}}',
    '{"personal":{"discovery_roots":["/p"],"x":1}}',
    '{"personal":{"discovery_roots":["/p"],"shared_infra_root":"/s"}}',
    '{"personal":{"discovery_roots":["/p"],"shared_infra_root":5}}',
    '{"personal":{"discovery_roots":["/p","/p/"]}}',
    '{"personal":{"discovery_roots":["/p"]},"Other":{"discovery_roots":["/q"]}}',
    '{"personal":{"discovery_roots":["/p"]},"other":5}',
    '{"personal":{"discovery_roots":"/p"}}',
    "[]",
    '{"personal":{"discovery_roots":[5]}}',
    '{"personal":{"discovery_roots":["/p"]},"'
    + "a" * 64
    + '":{"discovery_roots":["/q"]}}',
    '{"personal":{"discovery_roots":["/p"]},"'
    + "a" * 65
    + '":{"discovery_roots":["/q"]}}',
    '{"personal":{"discovery_roots":["/p"]},"o\\u0000":{"discovery_roots":["/q"]}}',
    '{"personal":{"discovery_roots":["/p"]},"personal":null}',
    '{"personal":null,"personal":{"discovery_roots":["/p"]}}',
]
for i, lit in enumerate(fleet_vals):
    put(f"fleets-{i:02d}", sub("fleets", lit.encode()))
for k in list(base):
    o = dict(base)
    del o[k]
    put(f"missing-{k}", raw(o))
for i, t in enumerate(
    [b"", b" ", b"\n", b"[]", b"1", b'"x"', b"null", b"{}", b"{", b"}"]
):
    put(f"top-{i}", t)
put("big-projects-1mb", sub("projects", b'"' + "é".encode() * 500000 + b'"'))
put("big-heavy-21digit", sub("heavy_slots", b"100000000000000000000"))
put("big-heavy-20digit", sub("heavy_slots", b"99999999999999999999"))
put("big-heavy-bigexp", sub("heavy_slots", b"1e400"))
put("big-heavy-long1", sub("heavy_slots", b"1." + b"0" * 30))
put("big-heavy-neg0", sub("heavy_slots", b"-0"))
put("big-light-21digit", sub("heavy_light_slots", b"200000000000000000000"))
put("gate-escaped-key", sub("process_gate_slots", b"2").replace(b"process_gate_", b"process_gate\\u005f"))
put("gate-malformed-json", sub("process_gate_slots", b"tru"))
for name, data in cases.items():
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in name)
    (out / (safe + ".json")).write_bytes(data)
print(len(cases))
