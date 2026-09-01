#!/usr/bin/env python3
"""Group fence refusals by cause. A count cannot distinguish a refusal that is
working from one that is a false positive; a grouped enumeration can."""
import re, sys, collections, pathlib

log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
refs = re.findall(r'test-git-fence: REFUSED: (.+)', log)
crashes = re.findall(r'(\S+): line (\d+): (.+?): unbound variable', log)

# Normalise: strip volatile paths so identical causes collapse into one group.
def norm(msg):
    m = re.sub(r'/[^\s\'"]*/(bats-run-\w+|trellis-test-git\.\w+|[0-9a-f]{8,})[^\s\'"]*', '<TMP>', msg)
    m = re.sub(r"'/[^']*'", "'<PATH>'", m)
    m = re.sub(r'/Users/\S+', '<PATH>', m)
    return m.strip()

groups = collections.Counter(norm(r) for r in refs)
print(f"total refusals: {len(refs)}   distinct causes: {len(groups)}")
print(f"unbound-variable crashes: {len(crashes)}")
if crashes:
    for (f,l,v), n in collections.Counter(crashes).most_common(5):
        print(f"   CRASH x{n} {f}:{l} {v}")
print()
for cause, n in groups.most_common():
    print(f"  {n:>6}  {cause}")
print()
# A pass requires every distinct cause to be explainable, not a small count.
print("VERDICT INPUT: each distinct cause above must be either")
print("  (a) a fixture correctly refused for mutating outside the root, or")
print("  (b) a consciously accepted known false positive.")
print("Unexplained groups -> FAIL, regardless of how few refusals there are.")
sys.exit(0 if not groups and not crashes else 1)
