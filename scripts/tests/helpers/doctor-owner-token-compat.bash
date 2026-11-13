#!/usr/bin/env bash
# The old HOME-root token is byte-for-byte unchanged; root=/ is new and must
# reject a coarse user-owned ancestor, while not silently missing every proof.
set -u
repo=$1
sandbox=$2
home="$sandbox/home"
parent="$home/owned"
file="$parent/record"
mkdir -p "$parent" "$sandbox/lib"
chmod 700 "$home" "$parent"
printf 'record\n' > "$file"
chmod 600 "$file"
. "$repo/scripts/lib/local-registry.sh"
plain='drwxr-xr-x  1 root root 1 Jan 1 00:00 /root'
xattr='drwxr-xr-x@ 1 root root 1 Jan 1 00:00 /root'
acl='drwxr-xr-x+ 1 root root 1 Jan 1 00:00 /root'
_local_registry_acl_listing_clear 1 "$plain" || { echo 'plain ACL-free listing refused'; exit 1; }
_local_registry_acl_listing_clear 1 "$xattr" || { echo 'xattr-only listing refused'; exit 1; }
if _local_registry_acl_listing_clear 1 "$acl" ||
   _local_registry_acl_listing_clear 1 "${xattr}"$'\n'' 0: user:someone allow write' ||
   _local_registry_acl_listing_clear 1 'unparseable listing' ||
   _local_registry_acl_listing_clear 2 "$plain"; then
  echo 'ACL or unparseable listing accepted'; exit 1
fi
echo 'ACL, masked ACL and malformed listings refused'
case "$(/usr/bin/uname -s)" in
  Darwin)
    old_rows="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 /usr/bin/stat -f $'%d\t%i\t%z\t%p\t%Fm\t%Fc' -- "$parent" "$home" "$file")" || exit 1
    root_row="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 /usr/bin/stat -f $'%d\t%i\t%z\t%p\t%Fm\t%Fc\t%u' -- /)" || exit 1
    if [ -d /private ]; then
      private_row="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 /usr/bin/stat -f $'%d\t%i\t%z\t%p\t%Fm\t%Fc\t%u' -- /private)" || exit 1
    else private_row=''; fi ;;
  Linux)
    old_rows="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 /usr/bin/stat --printf='%d\t%i\t%s\t%f\t%y\t%z\n' -- "$parent" "$home" "$file")" || exit 1
    root_row="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 /usr/bin/stat --printf='%d\t%i\t%s\t%f\t%y\t%z\t%u\n' -- /)" || exit 1
    private_row='' ;;
  *) echo 'unsupported platform'; exit 77 ;;
esac
actual="$(_local_registry_file_token "$parent" "$file" "$home")" || { echo 'HOME-root token unavailable'; exit 1; }
expected="$(printf '1\n%s\n' "$old_rows")"
[ "$actual" = "$expected" ] || { echo 'HOME-root token bytes changed'; exit 1; }
echo 'home token matches pre-change format'

if [ "$EUID" -eq 0 ]; then
  echo 'root proof skipped for root euid; coarse root timestamps must be refused'
  exit 77
fi
whole="$(_local_registry_file_token "$parent" "$file" /)" || { echo 'root token unexpectedly missed'; exit 1; }
printf '%s\n' "$whole" | grep -Fxq "$root_row" || { echo 'root missing from token'; exit 1; }
if [ -n "$private_row" ]; then
  printf '%s\n' "$whole" | grep -Fxq "$private_row" || { echo '/private missing from token'; exit 1; }
fi
echo 'root token proves the complete ancestor chain'

# In a private library copy, replace only stat's executable with a test shim
# that makes the USER-OWNED sandbox ancestor appear to have coarse ctime.
# The real system stat and all other token logic are otherwise unchanged.
fake="$sandbox/fake-stat"
cat > "$fake" <<'SH'
#!/bin/bash
/usr/bin/stat "$@" | /usr/bin/python3 -I -c '
import re, sys
for i, line in enumerate(sys.stdin):
    columns = line.rstrip("\n").split("\t")
    if i == 2:
        columns[5] = re.sub(r"\.\d{9}", ".000000000", columns[5])
    print("\t".join(columns))
'
SH
chmod 755 "$fake"
ln -s "$repo/scripts/lib/trellis-home.sh" "$sandbox/lib/trellis-home.sh"
/usr/bin/python3 -I - "$repo/scripts/lib/local-registry.sh" "$sandbox/lib/local-registry.sh" "$fake" <<'PY'
import sys
source, out, fake = sys.argv[1:]
data = open(source).read()
old = 'if [ -x /usr/bin/stat ]; then stat_bin=/usr/bin/stat'
new = 'if [ -x "' + fake + '" ]; then stat_bin="' + fake + '"'
assert data.count(old) == 1
open(out, 'w').write(data.replace(old, new))
PY
. "$sandbox/lib/local-registry.sh"
if _local_registry_file_token "$parent" "$file" / >/dev/null; then
  echo 'coarse user-owned ancestor was accepted'
  exit 1
fi
echo 'coarse user-owned ancestor refused'

# Also force the root-owned / row coarse. Its numeric uid and non-writable
# mode must allow a proof for a non-root user on both BSD and GNU stat.
fake_root="$sandbox/fake-root-stat"
/usr/bin/python3 -I - "$fake" "$fake_root" "$sandbox/lib/local-registry.sh" "$sandbox/lib/root-registry.sh" <<'PY'
import sys
fake, fake_root, lib, root_lib = sys.argv[1:]
source = open(fake).read()
source = source.replace('for i, line in enumerate(sys.stdin):', 'lines = list(sys.stdin)\nfor i, line in enumerate(lines):')
source = source.replace('if i == 2:', 'if i == len(lines) - 2:')
open(fake_root, 'w').write(source)
open(root_lib, 'w').write(open(lib).read().replace(fake, fake_root))
PY
chmod 755 "$fake_root"
. "$sandbox/lib/root-registry.sh"
_local_registry_file_token "$parent" "$file" / >/dev/null || { echo 'coarse root-owned / was incorrectly refused'; exit 1; }
echo 'coarse root-owned ancestor accepted for non-root user'
# A root-owned coarse node that becomes group-writable must still miss.
fake_writable="$sandbox/fake-writable-stat"
/usr/bin/python3 -I - "$fake_root" "$fake_writable" "$sandbox/lib/root-registry.sh" "$sandbox/lib/writable-registry.sh" <<'PY'
import sys
fake_root, fake_writable, lib, writable_lib = sys.argv[1:]
data = open(fake_root).read()
old = '    if i == len(lines) - 2:\n'
new = old + '        columns[3] = "40775" if sys.platform == "darwin" else "41fd"\n'
assert data.count(old) == 1
open(fake_writable, 'w').write(data.replace(old, new))
open(writable_lib, 'w').write(open(lib).read().replace(fake_root, fake_writable))
PY
chmod 755 "$fake_writable"
. "$sandbox/lib/writable-registry.sh"
if _local_registry_file_token "$parent" "$file" / >/dev/null; then
  echo 'coarse group-writable root-owned node was accepted'; exit 1
fi
echo 'coarse group-writable root-owned node refused'
/usr/bin/python3 -I - "$sandbox/lib/root-registry.sh" "$sandbox/lib/no-ls-registry.sh" <<'PY'
import sys
source, out = sys.argv[1:]
data = open(source).read()
assert data.count('/bin/ls -ld') == 2
open(out, 'w').write(data.replace('/bin/ls -ld', '/nonexistent/trellis-ls -ld'))
PY
. "$sandbox/lib/no-ls-registry.sh"
if _local_registry_file_token "$parent" "$file" / >/dev/null; then
  echo 'unavailable ACL probe was accepted'; exit 1
fi
echo 'unavailable ACL probe refused'
