# shellcheck shell=bash
# T39: a real non-APFS filesystem for the coarse-ctime fallback cases. HFS+
# keeps timestamps in whole seconds, so ctime cannot prove freshness there.
# A private sparse image, attached without Finder at a test-owned mount point;
# hfs_volume_detach runs from the suite teardown, even after a failed test.

# hfs_volume_attach: sets HFS_MNT to the canonical mount point, or skips off
# Darwin. Fails (never skips) when the image cannot be made or attached.
hfs_volume_attach() {
  [ "$(uname -s)" = Darwin ] || skip 'HFS+ coarse-ctime volume is a macOS fixture'
  local image="$BATS_TEST_TMPDIR/hfs-volume"
  HFS_MNT="$BATS_TEST_TMPDIR/hfs-mnt"
  mkdir -p "$HFS_MNT"
  /usr/bin/hdiutil create -quiet -size 512m -type SPARSE -fs 'HFS+' -volname trellis-coarse "$image" ||
    { echo 'hdiutil could not create the HFS+ image'; return 1; }
  /usr/bin/hdiutil attach -quiet -nobrowse -noautoopen -owners on -mountpoint "$HFS_MNT" "$image.sparseimage" ||
    { echo 'hdiutil could not attach the HFS+ image'; return 1; }
  HFS_ATTACHED="$HFS_MNT"
  HFS_MNT="$(cd "$HFS_MNT" && pwd -P)"
  /sbin/mount | grep -F " on $HFS_MNT (" | grep -q 'hfs' || { /sbin/mount | grep -F "$HFS_MNT"; echo 'not an HFS+ mount'; return 1; }
}

# hfs_volume_coarse_ctime: prove the capability rather than assume it: fresh
# files and a metadata change all carry whole-second ctimes.
hfs_volume_coarse_ctime() {
  python3 -I - "$HFS_MNT" <<'PY'
import os, sys, time
root = sys.argv[1]
for i in range(5):
    p = os.path.join(root, '.ctime-probe-%d' % i)
    with open(p, 'w') as f:
        f.write('x')
    os.chmod(p, 0o640)
    ns = os.stat(p).st_ctime_ns
    os.unlink(p)
    if ns % 1_000_000_000:
        sys.exit('fine ctime %d on the HFS+ volume' % ns)
    time.sleep(0.013)
PY
}

hfs_volume_detach() {
  [ -n "${HFS_ATTACHED:-}" ] || return 0
  find "$HFS_ATTACHED" -depth -type d -exec chmod u+w {} + 2>/dev/null || true
  /usr/bin/hdiutil detach -quiet -force "$HFS_ATTACHED" 2>/dev/null || true
  HFS_ATTACHED=''
}
