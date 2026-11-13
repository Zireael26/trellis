"""Privacy policy/command-selection oracle using private Bash function spies."""
import argparse
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('template', type=Path)
p.add_argument('scratch', type=Path)
p.add_argument('bash')
p.add_argument('mode', choices=('counts', 'policy'))
a = p.parse_args()
r = a.scratch
r.mkdir(mode=0o700)
(r/'directory').mkdir(mode=0o700)
(r/'config.json').write_text('{}')
(r/'config.json').chmod(0o600)
source = a.template.read_text()
names = ('launcher_acl_free_permissions', 'launcher_private_config', 'launcher_private_directory')
functions = []
for name in names:
    start = source.index(name+'() {')
    functions.append(source[start:source.index('\n}', start)+2])
spy = r'''
privacy_spy_ls() {
  printf 'ls|%s\n' "$1" >> "$SPY_LOG"
  if [ "$1" = -lde ] && { [ "$SPY_PLATFORM" = linux ] || [ "${SPY_FAIL_LDE-}" = 1 ]; }; then return 2; fi
  [ "${SPY_FAIL_ALL-}" != 1 ] || return 2
  [ "${SPY_EMPTY-}" != 1 ] || return 0
  printf '%s 1 fixture fixture 0 date %s\n' "$SPY_PERMS" "${@: -1}"
  [ "${SPY_ACL-}" != 1 ] || printf ' 0: user:fixture allow read\n'
  return 0
}
privacy_spy_uname() {
  printf 'uname|%s\n' "$1" >> "$SPY_LOG"
  if [ "$SPY_PLATFORM" = darwin ]; then printf 'Darwin\n'; else printf 'Linux\n'; fi
}
privacy_spy_printf() {
  printf 'printf|%s\n' "$1" >> "$SPY_LOG"
  builtin printf "$@"
}
privacy_spy_awk() {
  printf 'awk|%s\n' "$1" >> "$SPY_LOG"
  /usr/bin/awk "$@"
}
'''
text = '\n'.join(functions)
# The launcher applies the locale in env, after exec. Replace the whole external
# command so the in-process spy still observes the identical listing arguments.
text = text.replace('/usr/bin/env LC_ALL=C /bin/ls', 'privacy_spy_ls')
for path, name in (('/bin/ls', 'ls'), ('/usr/bin/uname', 'uname'), ('/usr/bin/printf', 'printf'), ('/usr/bin/awk', 'awk')):
    text = text.replace(path, 'privacy_spy_'+name)
script = r/'privacy.sh'
script.write_text(spy+'\n'+text+'\nOSTYPE="$1"\n"$2" "$3"\n')
log = r/'calls.txt'
# Initialize locale before Bash starts: Bash 5.3 can otherwise crash in a
# nested substitution assigning LC_ALL for the first time (not a policy error).
base = {'HOME': str(r), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C', 'SPY_LOG': str(log)}
rows = []
def run(platform, kind, permissions, expected, **options):
    log.write_text('')
    env = dict(base, SPY_PLATFORM=platform, SPY_PERMS=permissions, **options)
    system = {'linux': 'linux-gnu', 'darwin': 'darwin27.0', 'unknown': 'unknown'}[platform]
    function = 'launcher_private_directory' if kind == 'directory' else 'launcher_private_config'
    target = r/'directory' if kind == 'directory' else r/'config.json'
    result = subprocess.run([a.bash, str(script), system, function, str(target)], env=env, capture_output=True)
    calls = [line.split('|', 1) for line in log.read_text().splitlines()]
    row = dict(platform=platform, kind=kind, permissions=permissions, options=options, expected=expected, actual=result.returncode, calls=calls)
    rows.append(row)
    assert result.returncode == expected, (row, result.stdout, result.stderr)
    return calls
if a.mode == 'counts':
    for kind, permissions in (('directory', 'drwx------'), ('file', '-rw-------')):
        calls = run('linux', kind, permissions, 0)
        assert len(calls) == 1 and calls[0][:2] == ['ls', '-ld'], ('unneeded privacy subprocess', calls)
    print('two GNU privacy listing selections; zero uname/printf/awk selections')
else:
    file_modes = [('-rw-------',0),('-r--------',0),('-rwx------',0),('----------',0),('-rw-------@',0),('-rw-------+',1),('-rw-r-----',1),('-rw----r--',1),('-rws------',1),('-rwS------',1),('-rw---s---',1),('-rw------t',1)]
    directory_modes = [('drwx------',0),('dr-x------',0),('d---------',0),('drwx------@',0),('drwx------+',1),('drwxr-----',1),('drwx-----w',1),('drws------',0)]
    for platform in ('linux','darwin','unknown'):
        for kind, cases in (('file',file_modes),('directory',directory_modes)):
            for permissions, expected in cases:
                run(platform,kind,permissions,expected)
            perm='-rw-------@' if kind=='file' else 'drwx------@'
            run(platform,kind,perm,1,SPY_ACL='1')
            run(platform,kind,perm,1,SPY_EMPTY='1')
            run(platform,kind,perm,1,SPY_FAIL_ALL='1')
    for kind, perm in (('file','-rw-------'),('directory','drwx------')):
        calls=run('darwin',kind,perm,1,SPY_FAIL_LDE='1')
        assert not any(row[:2]==['ls','-ld'] for row in calls),('ACL-blind Darwin retry',calls)
    print(str(len(rows))+' private-mode/ACL/failure verdicts preserved, no Darwin blind retry')
(r/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
