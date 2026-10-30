"""Conservative donor reuse. Exit 10 is a read-only miss, never a partial attach.

Called with the existing checkout, attachment and registry locks held. Artifact
publication is batched here; schema, registry and hook checks remain in the
existing attachment machinery. Journals retain the v1 recovery contract.
"""
import base64
import copy
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid

# Resolve the shared verifier by absolute sibling path, never project sys.path.
# Import lazily so a broken sibling is a read-only fast miss, not an uncaught
# Python startup failure. The Bash gate checks both paths first as well.
integrity = None


def load_integrity():
    global integrity
    if integrity is None:
        spec = importlib.util.spec_from_file_location('release_executed', Path(__file__).with_name('release-executed.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        integrity = module
    return integrity


def directory(path):
    return load_integrity().directory(path)


def read_regular(*args, **kwargs):
    return load_integrity().read_regular(*args, **kwargs)


def relative(path):
    return load_integrity().relative(path)


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(data):
    return base64.b64encode(data).decode('ascii')


def identity(s):
    return '%d:%d' % (s.st_dev, s.st_ino)


def git(root, *args, data=None, allowed=(0,)):
    result = subprocess.run(['/usr/bin/git', '-C', root, *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode in allowed, 'Git preflight failed')
    return result.stdout


def live_identity(root, common):
    with directory(root):
        pass
    top = git(root, 'rev-parse', '--show-toplevel').decode().rstrip('\n')
    actual = git(root, 'rev-parse', '--git-common-dir').decode().rstrip('\n')
    if not os.path.isabs(actual):
        actual = os.path.join(root, actual)
    require(os.path.realpath(top) == root and os.path.realpath(actual) == common, 'checkout identity differs')


def artifact_exact(root, artifact):
    path = relative(artifact['path'])
    parent, name = os.path.split(root + '/' + path)
    with directory(parent) as fd:
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        kind = artifact['kind']
        if kind == 'symlink':
            require(stat.S_ISLNK(info.st_mode) and os.readlink(name, dir_fd=fd) == artifact['target'], 'donor symlink drift')
            return None
        if kind in ('directory', 'parent'):
            require(stat.S_ISDIR(info.st_mode), 'donor directory drift')
            if kind == 'directory':
                with directory(root + '/' + path) as child:
                    require(not os.listdir(child), 'donor empty directory drift')
            return None
        require(kind == 'file', 'unknown artifact kind')
    data = read_regular(root + '/' + path, mode=int(artifact['mode'], 8) if 'mode' in artifact else None)
    require(sha(data) == artifact['sha256'], 'donor file drift')
    return data


def current_inventory(donor, payload, harnesses):
    """Reject historical/adopted inventories that need the current full planner.

    Recognize the shipped nonrecursive link/render shapes only. Unknown shapes
    are misses, not a second permissive implementation of the general planner.
    """
    manifest_path = 'core-rules/inheritance-manifest.json'
    manifest = json.loads(read_regular(payload + '/' + manifest_path, sealed=True))
    require(manifest.get('schema_version') in (1, 2), 'unknown inheritance schema')
    selected = list(harnesses)
    if manifest['schema_version'] == 2 and any(h in harnesses for h in ('codex', 'pi')):
        selected.append('shared_agents')
    expected = {'.trellis/runtime': ('symlink', payload)}
    sources = [manifest_path]
    for harness in selected:
        section = manifest['harnesses'][harness]
        require(set(section) <= {'links', 'render'}, 'unknown surface shape')
        for entry in section.get('links', []):
            require(not entry.get('destination_home'), 'HOME surface in project plan')
            links = []
            if 'source_children' in entry:
                require(not entry.get('recursive'), 'complex expansion needs full planner')
                base = relative(entry['source_children'])
                with directory(payload + '/' + base) as fd:
                    for name in sorted(os.listdir(fd)):
                        if name in entry.get('exclude_dirs', []):
                            continue
                        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                        if entry['entry_type'] == 'directory' and stat.S_ISDIR(info.st_mode):
                            if entry.get('required_file'):
                                read_regular(payload + '/' + base + '/' + name + '/' + relative(entry['required_file']))
                            links.append((base + '/' + name, relative(entry['destination_dir']) + '/' + name))
                        elif entry['entry_type'] == 'file' and name.endswith(entry.get('suffix', '')):
                            require(stat.S_ISREG(info.st_mode), 'nonregular source child')
                            links.append((base + '/' + name, relative(entry['destination_dir']) + '/' + name))
            elif 'project_target' in entry:
                destination = relative(entry['destination'])
                source = relative(entry['project_target'])
                target = '../' * destination.count('/') + source
                if not os.path.isfile(donor['worktree_root'] + '/' + source):
                    target = '../' * destination.count('/') + '.trellis/runtime/' + relative(entry['fallback_source'])
                require(destination not in expected, 'duplicate surface destination')
                expected[destination] = ('symlink', target)
                continue
            else:
                links.append((relative(entry['source']), relative(entry['destination'])))
            for source, destination in links:
                require(destination not in expected, 'duplicate surface destination')
                expected[destination] = ('symlink', '../' * destination.count('/') + '.trellis/runtime/' + source)
        for entry in section.get('render', []):
            template, destination = relative(entry['template']), relative(entry['destination'])
            if not os.path.lexists(payload + '/' + template) and not entry.get('required', False):
                continue
            data = read_regular(payload + '/' + template, sealed=True)
            sources.append(template)
            require(destination not in expected, 'duplicate render destination')
            if entry['merge'] == 'replace':
                expected[destination] = ('file', sha(data), entry['mode'])
            else:
                require(entry['merge'] == 'explicit-json', 'unknown render merge')
                value = json.loads(data)
                context = donor.get('render_context') or {}
                replacements = {'__TRELLIS_USER_HOME__': context.get('user_home_shell'), '__TRELLIS_HOME__': context.get('trellis_home_shell'), '__TRELLIS_LAUNCHER__': context.get('launcher_shell')}
                def substitute(value):
                    if isinstance(value, str):
                        for token, replacement in replacements.items():
                            if token in value:
                                require(replacement is not None, 'missing render context')
                                value = value.replace(token, replacement)
                        return value
                    if isinstance(value, list):
                        return [substitute(item) for item in value]
                    if isinstance(value, dict):
                        return {key: substitute(item) for key, item in value.items()}
                    return value
                expected[destination] = ('json', substitute(value), entry['mode'])
    actual = {a['path']: a for a in donor['artifacts'] if a['kind'] != 'parent'}
    require(len(actual) == sum(a['kind'] != 'parent' for a in donor['artifacts']), 'duplicate donor leaves')
    require(set(actual) == set(expected), 'historical or incomplete donor inventory')
    for path, wanted in expected.items():
        artifact = actual[path]
        require(artifact['kind'] == ('file' if wanted[0] == 'json' else wanted[0]), 'surface kind differs')
        if wanted[0] == 'symlink':
            require(artifact['target'] == wanted[1], 'surface target differs')
        elif wanted[0] == 'file':
            require(artifact['sha256'] == wanted[1] and artifact.get('mode') == wanted[2], 'render template differs')
        else:
            data = artifact_exact(donor['worktree_root'], artifact)
            require(json.loads(data) == wanted[1] and artifact.get('mode') == wanted[2], 'guard template differs')
    return sources


def caller_toolchain():
    raw = os.environ.get('TRELLIS_ATTACH_CALLER_PATH', os.environ.get('PATH', ''))
    paths = []
    for entry in raw.split(':'):
        require(entry.startswith('/') and not any(ord(c) < 32 for c in entry), 'unsafe caller PATH')
        if not os.path.isdir(entry):
            require(not os.path.exists(entry), 'caller PATH nondirectory')
            continue
        actual = os.path.realpath(entry)
        with directory(actual):
            pass
        paths.append(actual)
    require(paths, 'empty caller toolchain')
    anchor = os.environ.get('TRELLIS_HOMEBREW_BIN', '/opt/homebrew/bin')
    if os.path.isdir(anchor) and os.path.realpath(anchor) == anchor:
        nvm = next((i for i, p in enumerate(paths) if '/.nvm/' in p or p.endswith('/.nvm')), None)
        if nvm is not None:
            at = paths.index(anchor) if anchor in paths else None
            if at is None:
                paths.insert(0, anchor)
            elif at > nvm:
                paths.pop(at)
                paths.insert(nvm, anchor)
    return paths


def native_directory_publish(fd, stage, name):
    """Exclusive rename, including against a concurrently created empty dir."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        function, flag = libc.renameatx_np, 4  # RENAME_EXCL
    elif sys.platform.startswith('linux') and hasattr(libc, 'renameat2'):
        function, flag = libc.renameat2, 1  # RENAME_NOREPLACE
    else:
        raise ValueError('exclusive directory rename unavailable')
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(fd, os.fsencode(stage), fd, os.fsencode(name), flag):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def json_bytes(value):
    # Same compact sorted serialization as _attachment_write_json / jq -cS.
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode()


def write_json(path, value, exclusive=False, on_publish=None):
    parent, name = os.path.split(path)
    with directory(parent) as fd:
        stage = '.' + name + '.fast-' + uuid.uuid4().hex
        out = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            with os.fdopen(out, 'wb') as stream:
                stream.write(json_bytes(value))
            if exclusive:
                os.link(stage, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
            else:
                os.replace(stage, name, src_dir_fd=fd, dst_dir_fd=fd)
            if on_publish is not None:
                on_publish()
        finally:
            try:
                os.unlink(stage, dir_fd=fd)
            except FileNotFoundError:
                pass  # replace consumed the staging name


PREFLIGHT = r'''
. "$1" || exit 1
home="$2"; registry="$3"; proposal="$4"; plan="$5"; authority="$6"; donor_owner="$7"
trap 'surface_plan_cleanup' EXIT
_SURFACE_PLAN_HARNESSES=()
while IFS= read -r harness; do _SURFACE_PLAN_HARNESSES+=("$harness"); done < <(jq -r '.[]' "$plan.harnesses")
release="$(jq -r .release "$plan")"
surface_plan_validate_manifest "$home/releases/$release/payload/core-rules/inheritance-manifest.json" || exit 1
shift 7
for owner in "$@"; do
  _attachment_owner_json_valid "$owner" && attach_exclude_verify_state "$(jq -c '.exclude' "$owner")" || { printf 'invalid exclude owner\n' >&2; exit 1; }
  if [ "$owner" = "$donor_owner" ]; then
    _attachment_verify_owner_artifacts_impl "$home" "$owner" || { printf 'non-exact donor owner\n' >&2; exit 1; }
  fi
done
_attachment_verify_managed_hooks "$home" "$authority" || { printf 'invalid managed hooks\n' >&2; exit 1; }
_attachment_validate_plan_file "$plan" || { printf 'invalid donor plan\n' >&2; exit 1; }
_attachment_validate_collisions "$(jq -c . "$plan")" || { printf 'donor plan collision\n' >&2; exit 1; }
_attachment_contextual_render_context_record_valid "$(jq -c . "$plan")" "$home" || { printf 'invalid plan context\n' >&2; exit 1; }
root="$(jq -r .worktree_root "$plan")"
identity="$(local_registry_identity_for_root "$root")" || exit 1
local_registry_propose_register_worktree "$registry" "$proposal" \
  "$(jq -r .fleet "$plan")" "$(jq -r .project_id "$plan")" \
  "$(printf '%s\n' "$identity" | jq -r .checkout_root)" \
  "$(printf '%s\n' "$identity" | jq -r .git_common_dir)" \
  "$(jq -r .checkout_id "$plan")" "$root" "$(jq -r .worktree_id "$plan")" \
  "$(jq -r .release "$plan")" "$(cat "$plan.harnesses")" \
  "$(jq -r .attachment_id "$plan")" '{}' bound-row || exit 1
'''


def prepare(home, root, fleet, project_id, binding, release, harnesses, expected_donor, attachment_id, root_pin, common_pin):
    checkout, worktree, common = binding['checkout_id'], binding['worktree_id'], binding['git_common_dir']
    require(binding['root'] == root and sha(root.encode()) == worktree and sha(common.encode()) == checkout, 'invalid identity binding')
    with directory(root) as fd:
        require(identity(os.fstat(fd)) == root_pin, 'root replaced')
    with directory(common) as fd:
        require(identity(os.fstat(fd)) == common_pin, 'common directory replaced')
    live_identity(root, common)
    state = home + '/state'
    owner_dir = state + '/attachments/' + checkout
    journal_dir = state + '/attachment-journals'
    owner_path = owner_dir + '/' + worktree + '.json'
    require(not os.path.lexists(owner_path), 'target already owned')
    require(not os.path.lexists(state + '/release-adoptions/' + checkout), 'pending adoption')
    for path in (home, state, state + '/attachments', owner_dir, journal_dir):
        with directory(path) as fd:
            require(stat.S_IMODE(os.fstat(fd).st_mode) == 0o700, 'nonprivate attachment state')
    with directory(journal_dir) as fd:
        require(not os.listdir(fd), 'pending journal')
    registry_path = home + '/registry.json'
    registry_bytes = read_regular(registry_path, mode=0o600)
    registry = json.loads(registry_bytes)
    project = registry['projects'][fleet + '/' + project_id]
    require(project['status'] == 'active' and not project.get('metadata', {}).get('legacy', {}).get('blacklisted', False), 'inactive checkout')
    require(root not in project.get('unavailable_roots', []), 'unavailable target')
    group = project['checkouts'][checkout]
    require(group['git_common_dir'] == common and group['release'] == release and sorted(group['harnesses']) == harnesses, 'release/harness mismatch')
    target_row = group['worktrees'].get(worktree, {'root': root})
    require(target_row['root'] == root and not target_row.get('attachment_id'), 'target registry conflict')
    rows = {key: row for key, row in group['worktrees'].items() if row.get('attachment_id')}
    require(rows and worktree not in rows, 'no attached donor')
    require(sys.platform == 'darwin' or (sys.platform.startswith('linux') and hasattr(ctypes.CDLL(None), 'renameat2')), 'exclusive directory publication unavailable')
    with directory(owner_dir) as fd:
        require(set(os.listdir(fd)) == {key + '.json' for key in rows}, 'orphan or unexpected owner state')
    owners, owner_files, owner_snapshots, authority = {}, [], {}, None
    for key, row in sorted(rows.items()):
        path = owner_dir + '/' + key + '.json'
        owner_snapshots[path] = read_regular(path, mode=0o600)
        record = json.loads(owner_snapshots[path])
        donor_root = row['root']
        require(donor_root != root and sha(donor_root.encode()) == key, 'donor root binding differs')
        live_identity(donor_root, common)
        manifest = json.loads(read_regular(donor_root + '/.trellis.json'))
        require(manifest.get('project_id') == project_id, 'donor project differs')
        for field, value in [('status', 'committed'), ('fleet', fleet), ('project_id', project_id), ('checkout_id', checkout), ('worktree_id', key), ('attachment_id', row['attachment_id']), ('release', release), ('project_root', donor_root), ('worktree_root', donor_root)]:
            require(record.get(field) == value, 'donor binding differs')
        if record.get('git_hooks', {}).get('enabled'):
            require(authority is None, 'multiple hook authorities')
            authority = path
        owners[key] = record
        owner_files.append(path)
    require(authority is not None, 'missing hook authority')
    donor = None
    candidates = [owners[expected_donor['worktree_id']]] if expected_donor else owners.values()
    for candidate in candidates:
        if not expected_donor and candidate.get('pre_existing'):
            continue  # Deferred leaves need fresh planning; try another donor.
        try:
            for artifact in candidate['artifacts']:
                artifact_exact(candidate['worktree_root'], artifact)
        except (OSError, ValueError):
            continue  # Native drift disqualifies this donor, not exclude ownership.
        donor = candidate
        break
    require(donor is not None, 'no exact donor')
    if expected_donor:
        require(donor['attachment_id'] == expected_donor['attachment_id'] and donor['worktree_root'] == expected_donor['root'], 'expected donor changed')
    require(not donor.get('pre_existing'), 'donor deferred leaves need fresh planning')
    require(all(not r['before_exists'] for r in donor.get('renders', [])), 'donor guards contain project content')
    toolchain = donor.get('toolchain_path', [])
    require(toolchain and any(p not in ('/usr/bin', '/bin', '/usr/sbin', '/sbin') for p in toolchain), 'donor toolchain absent/control-only')
    for path in toolchain:
        with directory(path):
            pass
    if not expected_donor:
        require(caller_toolchain() == toolchain, 'caller toolchain needs fresh capture')
        if donor.get('render_context'):
            require(donor['render_context']['user_home'] == os.path.realpath(os.environ.get('HOME', '')), 'different render home')
    require(os.path.isfile(root + '/CLAUDE.md') == os.path.isfile(donor['worktree_root'] + '/CLAUDE.md'), 'different project CLAUDE context')
    managed = state + '/git-hooks/' + checkout
    authority_record = owners[Path(authority).stem]
    hooks = authority_record['git_hooks']
    require(hooks['managed_hooks_path'] == managed, 'different managed hooks')
    require(git(root, 'config', '--local', '--get-all', 'core.hooksPath') == (managed + '\n').encode(), 'hooksPath mismatch')
    require(git(root, 'config', '--get', 'core.hooksPath') == (managed + '\n').encode(), 'effective hooksPath mismatch')
    pins = []
    for name in ('pre-push', 'post-checkout'):
        body = read_regular(managed + '/' + name, mode=0o700).decode()
        found = re.findall(r'^expected_release_manifest_sha256=([0-9a-f]{64})$', body, re.M)
        require(len(found) == 1, 'missing dispatcher manifest pin')
        pins.append(found[0])
    require(pins[0] == pins[1], 'dispatcher pins differ')
    payload = home + '/releases/' + release + '/payload'
    required = ['scripts/seed-inheritance-symlinks.sh', hooks['pre_push_source']] + current_inventory(donor, payload, harnesses)
    release_record = integrity.verify_release_executed(home + '/releases/' + release, pins[0], required)
    require(release_record['version'] == release, 'release version differs')
    exclude_path = common + '/info/exclude'
    exclude_bytes = read_regular(exclude_path)
    exclude = copy.deepcopy(authority_record['exclude'])
    require(exclude['managed_by_attachment'] and exclude['path'] == exclude_path and exclude['git_common_dir'] == common, 'exclude authority mismatch')
    require(exclude_bytes == base64.b64decode(exclude['after_base64'], validate=True), 'exclude bytes changed')
    for record in owners.values():
        require(record['exclude_block_hash'] == exclude['managed_block_sha256'] and record['exclude']['git_common_dir'] == common, 'sibling exclude differs')
    block = base64.b64decode(exclude['managed_block_base64'], validate=True)
    require(sha(block) == exclude['managed_block_sha256'] and exclude_bytes.count(block) == 1, 'exclude block differs')
    exclude.update(before_exists=True, before_sha256=sha(exclude_bytes), before_base64=encoded(exclude_bytes), after_exists=True, after_sha256=sha(exclude_bytes), after_base64=encoded(exclude_bytes), managed_by_attachment=False)
    leaves = [copy.deepcopy(a) for a in donor['artifacts'] if a['kind'] != 'parent']
    require(any(a == {'path': '.trellis/runtime', 'kind': 'symlink', 'target': payload} for a in leaves), 'runtime release anchor differs')
    parents = set()
    for artifact in leaves:
        path = relative(artifact['path'])
        require(not os.path.lexists(root + '/' + path), 'project-owned target leaf')
        parts = path.split('/')[:-1]
        parents.update('/'.join(parts[:i]) for i in range(1, len(parts) + 1))
        if artifact['kind'] == 'file':
            artifact['content_base64'] = encoded(artifact_exact(donor['worktree_root'], artifact))
    owned_parents = []
    for path in sorted(parents, key=lambda p: (p.count('/'), p)):
        if os.path.lexists(root + '/' + path):
            with directory(root + '/' + path):
                pass
        else:
            owned_parents.append({'path': path, 'kind': 'parent'})
    paths = [a['path'] for a in leaves]
    require(not git(root, 'ls-files', '-z', '--', *paths), 'tracked destination conflict')
    ignored = git(root, 'check-ignore', '-z', '--no-index', '--stdin', data=('\0'.join(paths) + '\0').encode(), allowed=(0, 1)).decode().split('\0')
    require(set(paths) <= set(ignored), 'exclude not effective')
    plan = copy.deepcopy(donor)
    plan.update(status='prepared', project_root=root, worktree_root=root, checkout_id=checkout, worktree_id=worktree, attachment_id=attachment_id, artifacts=owned_parents + leaves, exclude=exclude, git_hooks={'enabled': False})
    donor_owner = owner_dir + '/' + donor['worktree_id'] + '.json'
    return plan, registry_path, registry_bytes, owner_path, journal_dir + '/' + attachment_id + '.json', authority, donor_owner, owner_files, owner_snapshots


def publish(plan, owner_path, journal_path, root_pin, common_pin):
    root = plan['worktree_root']
    common = plan['exclude']['git_common_dir']
    def namespace():
        for path, pin in ((root, root_pin), (common, common_pin)):
            with directory(path) as fd:
                require(identity(os.fstat(fd)) == pin, 'namespace replaced')
    namespace()
    journal = json.loads(read_regular(journal_path, mode=0o600))
    require(journal == dict(plan, phase=0, applied=[], pending=None, removal=None), 'journal changed before publication')
    for artifact in plan['artifacts']:
        namespace()
        parent, name = os.path.split(root + '/' + artifact['path'])
        with directory(parent) as fd:
            stage = '.' + name + '.attachment-stage-' + plan['attachment_id'] + '.' + uuid.uuid4().hex
            journal['pending'] = dict(artifact=artifact, staging_path=parent + '/' + stage, staging_identity=None, destination_identity=None, parent_identity=identity(os.fstat(fd)))
            write_json(journal_path, journal)
            kind = artifact['kind']
            if kind in ('parent', 'directory'):
                os.mkdir(stage, 0o755, dir_fd=fd)
            elif kind == 'symlink':
                os.symlink(artifact['target'], stage, dir_fd=fd)
            else:
                out = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, int(artifact.get('mode', '0644'), 8), dir_fd=fd)
                with os.fdopen(out, 'wb') as stream:
                    stream.write(base64.b64decode(artifact['content_base64'], validate=True))
                    os.fchmod(stream.fileno(), int(artifact.get('mode', '0644'), 8))
            journal['pending']['staging_identity'] = identity(os.stat(stage, dir_fd=fd, follow_symlinks=False))
            write_json(journal_path, journal)
            if kind in ('parent', 'directory'):
                native_directory_publish(fd, stage, name)
            else:
                os.link(stage, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
                os.unlink(stage, dir_fd=fd)
            require(identity(os.stat(name, dir_fd=fd, follow_symlinks=False)) == journal['pending']['staging_identity'], 'publication identity differs')
            namespace()
            journal['phase'] += 1
            journal['applied'] = plan['artifacts'][:journal['phase']]
            journal['pending'] = None
            write_json(journal_path, journal)
        if os.environ.get('ATTACHMENT_FAULT_PHASE') == 'fast-published':
            raise ValueError('injected interruption after batch publication')
    namespace()
    managed = str(Path(journal_path).parent.parent / 'git-hooks' / plan['checkout_id'])
    require(git(root, 'config', '--local', '--get-all', 'core.hooksPath') == (managed + '\n').encode() and git(root, 'config', '--get', 'core.hooksPath') == (managed + '\n').encode(), 'hooksPath changed before commit')
    owner = copy.deepcopy(plan)
    owner['status'] = 'committed'
    for artifact in owner['artifacts']:
        artifact.pop('content_base64', None)
    write_json(owner_path, owner, exclusive=True)
    with directory(os.path.dirname(journal_path)) as fd:
        os.unlink(os.path.basename(journal_path), dir_fd=fd)


def main():
    mode = '--begin'
    started = False
    try:
        mode, workspace = sys.argv[1:3]
        started = mode == '--finish'
        load_integrity()
        require(mode in ('--begin', '--finish'), 'invalid phase')
        with directory(workspace) as fd:
            require(stat.S_IMODE(os.fstat(fd).st_mode) == 0o700, 'nonprivate workspace')
        plan_file, proposal = workspace + '/plan.json', workspace + '/registry.json'
        if mode == '--begin':
            home, root, fleet, project, binding, release, harnesses, expected_donor, attachment_id, root_pin, common_pin = sys.argv[3:]
            plan, registry_path, registry_before, owner_path, candidate, authority, donor_owner, owners, snapshots = prepare(home, root, fleet, project, json.loads(binding), release, json.loads(harnesses), json.loads(expected_donor or 'null'), attachment_id, root_pin, common_pin)
            # No project or persistent-state writes during eligibility validation.
            write_json(plan_file, plan, exclusive=True)
            with open(plan_file + '.harnesses', 'x') as stream:
                stream.write(harnesses)
            os.chmod(plan_file + '.harnesses', 0o600)
            env = dict(os.environ, TRELLIS_LIBS_PRELOADED='0')
            result = subprocess.run(['/bin/bash', '-c', PREFLIGHT, 'fast-preflight', str(Path(__file__).parent.parent / 'attach-project.sh'), home, registry_path, proposal, plan_file, authority, donor_owner, *owners], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            require(result.returncode == 0, 'existing attachment preflight refused: ' + result.stderr.decode(errors='replace')[-2000:])
            json.loads(read_regular(proposal))
            # The only persistent write in begin: a recoverable v1 journal.
            for path, before in snapshots.items():
                require(read_regular(path, mode=0o600) == before, 'donor changed during preflight')
            require(read_regular(registry_path, mode=0o600) == registry_before, 'registry changed during preflight')
            require(not os.path.lexists(candidate), 'journal appeared during preflight')
            with directory(root) as fd:
                require(identity(os.fstat(fd)) == root_pin, 'root replaced')
            with directory(os.path.dirname(candidate)):
                pass
            write_json(candidate, dict(plan, phase=0, applied=[], pending=None, removal=None), exclusive=True)
            return 0
        # The calling Bash process holds the registry lock and performs the
        # bound-row write through local_registry_write_locked_bound_rows.
        plan = json.loads(read_regular(plan_file, mode=0o600))
        registry_path = sys.argv[3] + '/registry.json'
        root_pin, common_pin = sys.argv[4:6]
        require(json.loads(read_regular(registry_path, mode=0o600)) == json.loads(read_regular(proposal)), 'registry API write differs from proposal')
        owner_path = sys.argv[3] + '/state/attachments/' + plan['checkout_id'] + '/' + plan['worktree_id'] + '.json'
        candidate = sys.argv[3] + '/state/attachment-journals/' + plan['attachment_id'] + '.json'
        publish(plan, owner_path, candidate, root_pin, common_pin)
        print(owner_path)
        return 0
    except Exception as error:
        if started or (mode == '--begin' and 'candidate' in locals() and os.path.lexists(candidate)):
            print('trellis attach: donor batch interrupted; run trellis recover: ' + str(error), file=sys.stderr)
            return 3
        if os.environ.get('TRELLIS_FASTPATH_TRACE') == '1':
            print('trellis attach: donor fast-path miss: ' + repr(str(error)), file=sys.stderr)
        return 10


if __name__ == '__main__':
    sys.exit(main())
