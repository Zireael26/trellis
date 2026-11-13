# Produce the historical supervisor fixture, which predates QUIT handling.
make_legacy_heavy_supervisor() {
  python3 -I - "$1" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text()
for old,new in [('SIGHUP SIGQUIT SIG_BLOCK','SIGHUP SIG_BLOCK'),('HUP => SIGHUP, QUIT => SIGQUIT','HUP => SIGHUP'),('SIGINT, SIGTERM, SIGHUP, SIGQUIT','SIGINT, SIGTERM, SIGHUP')]:
    assert s.count(old)==1
    s=s.replace(old,new)
assert s.count('qw(INT TERM HUP QUIT)') == 2
s=s.replace('qw(INT TERM HUP QUIT)', 'qw(INT TERM HUP)')
p.write_text(s)
PY
}
