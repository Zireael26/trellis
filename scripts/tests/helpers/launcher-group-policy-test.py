#!/usr/bin/env python3
"""Exercise doctor and installer's actual directory logic on the same NSS fixtures.

Only this test replaces passwd/group/filesystem calls. Production receives no
fixture environment variables and the installer function body is not copied.
"""
import ast
import pathlib
import stat
import sys
import types

health_path, home_path, policy_path, mode = sys.argv[1:]
health = pathlib.Path(health_path).read_text().split('hc_launcher_currency() {', 1)[1]
health_py = health.split("<<'PY'", 1)[1].split('\nPY\n', 1)[0]
installer = pathlib.Path(home_path).read_text().split('trellis_home_publish_native_launcher() {', 1)[1]
installer_py = installer.split("<<'PY'", 1)[1].split('\nPY\n', 1)[0]
health_ast = ast.parse(health_py)
installer_ast = ast.parse(installer_py)
policy = pathlib.Path(policy_path).read_text()
policy_ast = ast.parse(policy) if policy.strip() else health_ast
predicate = [n for n in policy_ast.body if isinstance(n, ast.FunctionDef) and n.name == 'launcher_directory_safe']
assert len(predicate) == 1, 'expected one shared launcher directory predicate'
installer_fn = [n for n in installer_ast.body if isinstance(n, ast.FunctionDef) and n.name == 'directory']
assert len(installer_fn) == 1
calls = [n for n in ast.walk(health_ast) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
         and n.func.id == 'require' and len(n.args) > 1 and isinstance(n.args[1], ast.Constant)
         and n.args[1].value == 'unsafe launcher directory']
assert len(calls) == 1
health_expr = compile(ast.Expression(calls[0].args[0]), 'doctor-check', 'eval')

class O:
    O_RDONLY = 1
    O_DIRECTORY = 2
    O_NOFOLLOW = 4
    uid = 1000
    gid = 1000
    st = None
    getuid = staticmethod(lambda: O.uid)
    getgid = staticmethod(lambda: O.gid)
    open = staticmethod(lambda *a, **kw: 1)
    close = staticmethod(lambda fd: None)
    fstat = staticmethod(lambda fd: O.st)
    mkdir = staticmethod(lambda *a, **kw: None)

class P:
    rows = []
    fail = False
    empty = False
    @staticmethod
    def getpwuid(uid):
        return next(r for r in P.rows if r.pw_uid == uid)
    @staticmethod
    def getpwall():
        if P.fail:
            raise OSError('passwd enumeration unavailable')
        return [] if P.empty else P.rows

class G:
    rows = []
    direct = None
    fail = False
    empty = False
    @staticmethod
    def getgrgid(gid):
        if G.direct is not None:
            return G.direct
        return next(r for r in G.rows if r.gr_gid == gid)
    @staticmethod
    def getgrall():
        if G.fail:
            raise OSError('group enumeration unavailable')
        return [] if G.empty else G.rows

def user(name, uid, gid):
    return types.SimpleNamespace(pw_name=name, pw_uid=uid, pw_gid=gid)

def group(name, gid, members=()):
    return types.SimpleNamespace(gr_name=name, gr_gid=gid, gr_mem=list(members))

def require(ok, message, *args):
    if not ok:
        raise ValueError(message)

ns = {'os': O, 'pwd': P, 'grp': G, 'Path': pathlib.Path, 'stat': stat,
      'require': require, 'no_acl': lambda fd: None}
exec(compile(ast.Module(body=predicate + installer_fn, type_ignores=[]), 'real-policy', 'exec'), ns)
# Exercise both real destination-parent call sites, not just the directory
# helper: dropping the policy flag at either site must fail this same fixture.
parent_calls = [n for n in ast.walk(installer_ast) if isinstance(n, ast.Call)
                and isinstance(n.func, ast.Name) and n.func.id == 'directory'
                and n.args and isinstance(n.args[0], ast.Attribute)
                and isinstance(n.args[0].value, ast.Name)
                and n.args[0].value.id == 'destination' and n.args[0].attr == 'parent']
assert len(parent_calls) == 2, 'expected both real installer parent checks'
parent_exprs = [compile(ast.Expression(n), 'installer-parent-call', 'eval') for n in parent_calls]
ns['destination'] = types.SimpleNamespace(parent=pathlib.Path('/home/user/.local/bin'))

def reset():
    O.uid, O.gid = 1000, 1000
    O.st = types.SimpleNamespace(st_uid=1000, st_gid=1000, st_mode=0o775)
    P.rows, P.fail, P.empty = [user('alice', 1000, 1000)], False, False
    G.rows, G.direct, G.fail, G.empty = [group('alice', 1000)], None, False, False

def results():
    ns['directory'] = O.st
    doctor = bool(eval(health_expr, ns))
    # Recreate the extracted function after assigning the doctor local: the
    # actual function uses its own `directory` variable in neither path.
    exec(compile(ast.Module(body=installer_fn, type_ignores=[]), 'installer-directory', 'exec'), ns)
    try:
        for expression in parent_exprs:
            eval(expression, ns)
        install = True
    except (ValueError, KeyError, OSError, StopIteration):
        install = False
    return doctor, install

if mode == 'same-fixture':
    reset()
    assert results() == (True, True), 'private 0775: doctor and installer must both accept'
    reset(); G.rows = [group('staff', 1000)]
    assert results() == (False, False), 'shared-name 0775: doctor and installer must both reject'
    reset(); G.rows = [group('staff', 1000, ['bob'])]
    assert results() == (False, False), 'shared 0775: doctor and installer must both reject'
    reset(); G.rows = [group('alice', 1000, ['alice', 'bob'])]
    assert results() == (False, False), 'foreign explicit group member accepted'
    reset(); G.direct = group('alice', 1000, ['bob'])
    assert results() == (False, False), 'foreign direct-lookup group member accepted'
    reset(); G.rows.append(group('alias', 1000, ['alice']))
    assert results() == (True, True), 'safe duplicate-gid alias refused'
    reset(); O.st.st_gid = 1001
    P.rows = [user('alice', 1000, 1001)]; G.rows = [group('alice', 1001)]
    assert results() == (False, False), 'non-primary group accepted'
    reset(); O.st.st_uid = 1001
    assert results() == (False, False), 'foreign owner accepted'
    reset(); O.st.st_mode = 0o777
    assert results() == (False, False), '0777: doctor and installer must both reject'
    reset(); O.st.st_mode = 0o755
    assert results() == (True, True), '0755: doctor and installer must both accept'
elif mode == 'enumeration':
    reset(); P.rows.append(user('bob', 1001, 1000))
    assert results() == (False, False), 'foreign primary gid accepted'
    reset(); O.uid = O.gid = O.st.st_uid = O.st.st_gid = 0
    P.rows = [user('root', 0, 0)]; G.rows = [group('root', 0)]
    assert results() == (False, False), 'gid 0 accepted without another enumerated account'
    P.rows.append(user('sync', 4, 0))
    assert results() == (False, False), 'gid 0 accepted with another primary account'
    reset(); G.rows.append(group('devs', 1000, ['bob']))
    assert results() == (False, False), 'duplicate gid with foreign member accepted'
    reset(); P.fail = True
    assert results() == (False, False), 'passwd enumeration failure accepted'
    reset(); G.fail = True
    assert results() == (False, False), 'group enumeration failure accepted'
    reset(); P.empty = True
    assert results() == (False, False), 'empty passwd enumeration accepted'
    reset(); G.empty = True
    assert results() == (False, False), 'empty group enumeration accepted'
else:
    raise SystemExit('unknown test mode')
