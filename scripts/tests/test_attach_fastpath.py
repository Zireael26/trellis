"""A5B synchronous integrity contract, no installed/live home access."""
from contextlib import ExitStack, contextmanager
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

LIB = Path(__file__).resolve().parents[1] / 'lib'
# Unpatched, for tests that must start a real child under a mocked preflight.
REAL_RUN = subprocess.run


class ExecutedIntegrityTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('release_executed', LIB / 'release-executed.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory(prefix='a5b.integrity.', dir=os.environ.get('TMPDIR', '/tmp'))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.release = self.root / '1.2.3'
        self.payload = self.release / 'payload'
        self.files = {
            'scripts/seed-inheritance-symlinks.sh': b'#!/bin/bash\nexit 0\n',
            'scripts/lib/sourced.sh': b'helper() { :; }\n',
            'core-rules/githooks/pre-push': b'#!/bin/bash\nexit 0\n',
            'core-rules/hooks/guard.py': b'pass\n',
            'core-rules/docs/policy.md': b'# deferred full audit\n',
        }
        rows = []
        for name, content in self.files.items():
            path = self.payload / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            mode = '100755' if name.endswith('pre-push') else '100644'
            path.chmod(int(mode[-3:], 8) & ~0o222)
            # Fixture Git blob object ID, not a cryptographic signature.
            oid = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()  # nosemgrep: python.lang.security.insecure-hash-algorithms.insecure-hash-algorithm-sha1
            rows.append({'path': name, 'mode': mode, 'oid': oid})
        self.record = self.release / 'release.json'
        self.record.write_text(json.dumps({'schema_version': 1, 'version': '1.2.3', 'tag': 'v1.2.3', 'tree': rows}))
        self.record.chmod(0o444)
        self.pin = hashlib.sha256(self.record.read_bytes()).hexdigest()
        for current, _, _ in os.walk(self.release):
            os.chmod(current, 0o555)
        self.addCleanup(self.unseal)

    def unseal(self):
        for current, _, _ in os.walk(self.root):
            # Owner-only test directories need write/search access for cleanup.
            os.chmod(current, 0o700)  # nosemgrep: python.lang.security.audit.insecure-file-permissions.insecure-file-permissions

    def verify(self):
        return self.module.verify_release_executed(str(self.release), self.pin, ['scripts/seed-inheritance-symlinks.sh', 'core-rules/githooks/pre-push'])

    def corrupt(self, name):
        path = self.payload / name
        path.chmod(0o644)
        path.write_bytes(b'tampered\n')
        path.chmod(0o444)

    def test_valid_release(self):
        self.assertEqual(self.verify()['version'], '1.2.3')

    def test_private_store_owner_only_modes_are_valid(self):
        for row in json.loads(self.record.read_text())['tree']:
            (self.payload / row['path']).chmod(0o500 if row['mode'] == '100755' else 0o400)
        self.assertEqual(self.verify()['version'], '1.2.3')

    def test_executable_bit_matches_manifest(self):
        (self.payload / 'core-rules/githooks/pre-push').chmod(0o400)
        with self.assertRaises(ValueError):
            self.verify()

    def test_manifest_pin_mismatch(self):
        self.pin = '0' * 64
        with self.assertRaises(ValueError):
            self.verify()

    def test_seeder_tamper(self):
        self.corrupt('scripts/seed-inheritance-symlinks.sh')
        with self.assertRaises(ValueError):
            self.verify()

    def test_sourced_library_tamper(self):
        self.corrupt('scripts/lib/sourced.sh')
        with self.assertRaises(ValueError):
            self.verify()

    def test_guard_tamper(self):
        self.corrupt('core-rules/hooks/guard.py')
        with self.assertRaises(ValueError):
            self.verify()

    def test_carrier_tamper(self):
        self.corrupt('core-rules/githooks/pre-push')
        with self.assertRaises(ValueError):
            self.verify()

    def test_nonexecuted_docs_are_deferred(self):
        self.corrupt('core-rules/docs/policy.md')
        self.assertEqual(self.verify()['version'], '1.2.3')

    def test_missing_executed_file(self):
        parent = self.payload / 'scripts/lib'
        parent.chmod(0o700)
        (parent / 'sourced.sh').unlink()
        parent.chmod(0o555)
        with self.assertRaises((ValueError, OSError)):
            self.verify()

    def test_symlink_executed_file(self):
        path = self.payload / 'scripts/lib/sourced.sh'
        path.parent.chmod(0o700)
        path.unlink()
        path.symlink_to(self.payload / 'core-rules/docs/policy.md')
        path.parent.chmod(0o555)
        with self.assertRaises((ValueError, OSError)):
            self.verify()

    def test_symlink_parent(self):
        parent = self.payload / 'scripts/lib'
        parent.parent.chmod(0o700)
        parent.chmod(0o700)
        parent.rename(self.root / 'moved')
        parent.symlink_to(self.root / 'moved')
        parent.parent.chmod(0o555)
        with self.assertRaises((ValueError, OSError)):
            self.verify()

    def test_writable_executed_file(self):
        (self.payload / 'scripts/lib/sourced.sh').chmod(0o644)
        with self.assertRaises(ValueError):
            self.verify()

    def test_writable_executed_parent(self):
        (self.payload / 'scripts/lib').chmod(0o755)
        with self.assertRaises(ValueError):
            self.verify()

    def test_writable_payload_root(self):
        self.payload.chmod(0o755)
        with self.assertRaises(ValueError):
            self.verify()

    def test_writable_release_root(self):
        self.release.chmod(0o755)
        with self.assertRaises(ValueError):
            self.verify()

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS ACL fixture')
    def test_acl_on_executed_file(self):
        path = self.payload / 'scripts/lib/sourced.sh'
        user = subprocess.check_output(['/usr/bin/id', '-un'], text=True).strip()
        subprocess.run(['/bin/chmod', '+a', 'user:%s allow write' % user, str(path)], check=True)
        path.chmod(0o444)
        # macOS can display @ rather than + when a file has both xattrs and
        # an ACL. The explicit ACL listing is the load-bearing evidence.
        self.assertIn(b'allow write', subprocess.check_output(['/bin/ls', '-lde', str(path)]))
        with self.assertRaises(ValueError):
            self.verify()

    def _linux_acl(self, listed):
        """check_fd_acl on Linux with no POSIX ACL; listed is what listxattr
        returns, or the OSError it raises."""
        import errno

        def getxattr(fd, name):
            raise OSError(errno.ENODATA, 'no data')

        def listxattr(fd):
            if isinstance(listed, OSError):
                raise listed
            return listed

        with patch.object(self.module.sys, 'platform', 'linux'), \
                patch.object(self.module.os, 'getxattr', getxattr, create=True), \
                patch.object(self.module.os, 'listxattr', listxattr, create=True):
            return self.module.check_fd_acl(0)

    def test_linux_nfs4_acl_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'carries an ACL'):
            self._linux_acl(['user.other', 'system.nfs4_acl'])

    def test_linux_richacl_and_file_capability_are_refused(self):
        # r151-muse LOW-3: RichACL and setcap entries passed as clean.
        for name in ('system.richacl', 'security.capability'):
            with self.subTest(xattr=name), self.assertRaisesRegex(ValueError, 'carries an ACL'):
                self._linux_acl(['user.other', name])

    def test_linux_xattr_enumeration_failure_is_undecided(self):
        import errno
        with self.assertRaises(OSError):
            self._linux_acl(OSError(errno.EOPNOTSUPP, 'unsupported'))

    def test_linux_without_acl_xattrs_is_clean(self):
        self.assertIsNone(self._linux_acl(['user.other']))

    def test_hardlinked_executed_file(self):
        os.link(self.payload / 'scripts/lib/sourced.sh', self.root / 'alias')
        with self.assertRaises(ValueError):
            self.verify()

    def test_required_entry_missing_from_manifest(self):
        with self.assertRaises(ValueError):
            self.module.verify_release_executed(str(self.release), self.pin, ['missing'])

    def test_malformed_manifest_cannot_supply_an_escaping_path(self):
        record = json.loads(self.record.read_text())
        record['tree'][0]['path'] = '../outside'
        self.record.chmod(0o644)
        self.record.write_text(json.dumps(record))
        self.record.chmod(0o444)
        self.pin = hashlib.sha256(self.record.read_bytes()).hexdigest()
        with self.assertRaises(ValueError):
            self.verify()


class FastInventoryTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory(prefix='a5b.inventory.', dir=os.environ.get('TMPDIR', '/tmp'))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.payload = self.root / 'payload'
        self.donor_root = self.root / 'donor'
        (self.payload / 'core-rules').mkdir(parents=True)
        (self.donor_root / '.claude').mkdir(parents=True)
        self.template = 'core-rules/guard.json'
        (self.payload / self.template).write_text('{"guard":"__TRELLIS_HOME__"}')
        (self.payload / self.template).chmod(0o444)
        self.manifest_path = self.payload / 'core-rules/inheritance-manifest.json'
        self.manifest = {'schema_version': 1, 'harnesses': {'claude': {'links': [], 'render': [{'template': self.template, 'destination': '.claude/settings.local.json', 'merge': 'explicit-json', 'mode': '0600', 'required': True}]}}}
        self.save_manifest()
        self.guard = self.donor_root / '.claude/settings.local.json'
        self.guard.write_text('{"guard":"\'fixture home\'"}\n')
        self.guard.chmod(0o600)
        self.donor = {'worktree_root': str(self.donor_root), 'render_context': {'trellis_home_shell': "'fixture home'"}, 'artifacts': [{'path': '.trellis/runtime', 'kind': 'symlink', 'target': str(self.payload)}, {'path': '.claude/settings.local.json', 'kind': 'file', 'mode': '0600', 'sha256': hashlib.sha256(self.guard.read_bytes()).hexdigest()}]}

    def save_manifest(self):
        if self.manifest_path.exists():
            self.manifest_path.chmod(0o644)
        self.manifest_path.write_text(json.dumps(self.manifest))
        self.manifest_path.chmod(0o444)

    def check(self):
        return self.module.current_inventory(self.donor, str(self.payload), ['claude'])

    def test_current_guard_reuses_context_and_inventory(self):
        self.assertEqual(self.check(), ['core-rules/inheritance-manifest.json', self.template])

    def test_native_template_is_deferred_to_the_canonical_renderer(self):
        (self.payload / self.template).chmod(0o644)
        (self.payload / self.template).write_text(json.dumps({'hooks': {'Stop': [{'hooks': [
            {'type': 'command', 'command': '__TRELLIS_LAUNCHER__', 'args': ['hook', 'event', 'claude', 'Stop'], 'timeout': 30}]}]}}))
        (self.payload / self.template).chmod(0o444)
        with self.assertRaises(ValueError):
            self.check()  # never by substitution
        native = []
        self.assertEqual(self.module.current_inventory(self.donor, str(self.payload), ['claude'], native),
                         ['core-rules/inheritance-manifest.json', self.template])
        self.assertEqual(native, [{'template': self.template, 'destination': '.claude/settings.local.json',
                                   'mode': '0600', 'merge': 'explicit-json'}])
        self.donor['artifacts'][-1]['mode'] = '0644'
        with self.assertRaises(ValueError):
            self.module.current_inventory(self.donor, str(self.payload), ['claude'], [])

    def test_render_miss_labels_name_the_host_difference(self):
        def doc(*targets):
            return {'hooks': {'Stop': [{'hooks': [{'command': '/h/bin/native/1.5.0/' + t + '/' + 'a' * 64 + '/trellis-hooks'} for t in targets]}]}}
        label = self.module.render_miss_label
        self.assertEqual(label(doc('x86_64-unknown-linux-musl'), doc('aarch64-apple-darwin')), 'donor render is for another host target')
        self.assertEqual(label(doc(), doc('aarch64-apple-darwin')), 'legacy donor render; this host renders native')
        self.assertEqual(label(doc('aarch64-apple-darwin'), doc()), 'native donor render; this host renders legacy')
        self.assertEqual(label(doc('aarch64-apple-darwin'), dict(doc('aarch64-apple-darwin'), extra=1)), 'donor render differs from its own root render')
        self.assertTrue(issubclass(self.module.RenderMiss, ValueError))

    def test_historical_inventory_is_a_miss(self):
        self.donor['artifacts'].pop()
        with self.assertRaises(ValueError):
            self.check()

    def test_extra_inventory_is_a_miss(self):
        self.donor['artifacts'].append({'path': 'extra', 'kind': 'directory'})
        with self.assertRaises(ValueError):
            self.check()

    def test_duplicate_inventory_is_a_miss(self):
        self.donor['artifacts'].append(dict(self.donor['artifacts'][-1]))
        with self.assertRaises(ValueError):
            self.check()

    def test_guard_from_an_old_template_is_a_miss(self):
        (self.payload / self.template).chmod(0o644)
        (self.payload / self.template).write_text('{"new_guard":true}')
        (self.payload / self.template).chmod(0o444)
        with self.assertRaises(ValueError):
            self.check()

    def test_wrong_guard_mode_is_a_miss(self):
        self.donor['artifacts'][-1]['mode'] = '0644'
        with self.assertRaises(ValueError):
            self.check()

    def test_missing_context_is_a_miss(self):
        self.donor.pop('render_context')
        with self.assertRaises(ValueError):
            self.check()

    def test_unknown_manifest_version_is_a_miss(self):
        self.manifest['schema_version'] = 3
        self.save_manifest()
        with self.assertRaises(ValueError):
            self.check()

    def test_complex_expansion_is_a_miss(self):
        self.manifest['harnesses']['claude']['links'].append({'source_children': 'core-rules', 'destination_dir': '.claude/rules', 'entry_type': 'file', 'recursive': True})
        self.save_manifest()
        with self.assertRaises(ValueError):
            self.check()

    def test_excluded_skill_child_is_not_a_project_leaf(self):
        for name in ('kept', 'user-only'):
            (self.payload / 'core-rules/skills' / name).mkdir(parents=True)
            (self.payload / 'core-rules/skills' / name / 'SKILL.md').write_text('# skill\n')
        self.manifest['harnesses']['claude']['links'].append({'source_children': 'core-rules/skills', 'destination_dir': '.claude/skills', 'entry_type': 'directory', 'required_file': 'SKILL.md', 'exclude_dirs': ['user-only']})
        self.save_manifest()
        self.donor['artifacts'].append({'path': '.claude/skills/kept', 'kind': 'symlink', 'target': '../../.trellis/runtime/core-rules/skills/kept'})
        self.check()
        self.donor['artifacts'].append({'path': '.claude/skills/user-only', 'kind': 'symlink', 'target': '../../.trellis/runtime/core-rules/skills/user-only'})
        with self.assertRaises(ValueError):
            self.check()

    def test_casefold_inventory_collision_needs_canonical_preflight(self):
        for leaf in ('Foo', 'foo'):
            self.manifest['harnesses']['claude']['links'].append(
                {'source': 'core-rules/CLAUDE.md', 'destination': '.agents/' + leaf})
            self.donor['artifacts'].append(
                {'path': '.agents/' + leaf, 'kind': 'symlink',
                 'target': '../.trellis/runtime/core-rules/CLAUDE.md'})
        self.save_manifest()
        self.check()  # The donor inventory map is case-sensitive.
        script = self.root / 'preflight-stubs.sh'
        script.write_text('''
. "$T13_ATTACHMENT_LIB"
surface_plan_cleanup() { :; }
surface_plan_validate_manifest() { :; }
surface_plan_validate_expanded_skills() { :; }
_attachment_verify_managed_hooks() { :; }
_attachment_validate_plan_file() { :; }
_attachment_contextual_render_context_record_valid() { :; }
local_registry_identity_for_root() { printf '%s\\n' '{"checkout_root":"/fixture","git_common_dir":"/fixture"}'; }
local_registry_propose_register_worktree() { :; }
''')
        plan = self.root / 'plan.json'
        Path(str(plan) + '.harnesses').write_text('["claude"]\n')
        data = {'release': '1.2.3', 'worktree_root': str(self.root), 'fleet': 'personal',
                'project_id': 'fixture', 'checkout_id': 'checkout', 'worktree_id': 'worktree',
                'attachment_id': 'attachment', 'artifacts': self.donor['artifacts']}
        env = dict(os.environ, T13_ATTACHMENT_LIB=str(LIB / 'attachment.sh'))
        def preflight():
            plan.write_text(json.dumps(data))
            return subprocess.run(['/bin/bash', '-c', self.module.PREFLIGHT, 't13-collision', str(script),
                                   str(self.root), str(self.root / 'registry'), str(self.root / 'proposal'),
                                   str(plan), str(self.root / 'authority'), str(self.root / 'donor'),
                                   str(self.root / 'exclude'), 'exclude.captured', ''],
                                  env=env, capture_output=True, text=True)
        collision = preflight()
        self.assertNotEqual(collision.returncode, 0)
        self.assertIn('donor plan collision', collision.stderr)
        data['artifacts'] = data['artifacts'][:-1]
        control = preflight()
        self.assertEqual(control.returncode, 0, control.stderr)

    def test_hardlinked_donor_file_is_stricter_than_canonical_exact_check(self):
        file = self.donor_root / 'file'
        file.write_bytes(b'unchanged\n')
        file.chmod(0o600)
        os.link(file, self.root / 'hardlink')
        artifact = {'path': 'file', 'kind': 'file', 'sha256': hashlib.sha256(file.read_bytes()).hexdigest(),
                    'mode': '0600'}
        result = subprocess.run(['/bin/bash', '-c', '. "$1"; _attachment_artifact_exact "$2" "$3"',
                                 't13-artifact', str(LIB / 'attachment.sh'), str(self.donor_root),
                                 json.dumps(artifact)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.assertRaises(ValueError):
            self.module.artifact_exact(str(self.donor_root), artifact)

    def test_owner_publish_never_replaces_a_project_file(self):
        path = self.root / 'owner.json'
        path.write_text('keep')
        with self.assertRaises(FileExistsError):
            self.module.write_json(str(path), {}, exclusive=True)
        self.assertEqual(path.read_text(), 'keep')

    def test_atomic_replace_finishes_without_removing_the_published_file(self):
        path = self.root / 'registry.json'
        path.write_text('{}')
        self.module.write_json(str(path), {'next': 1})
        self.assertEqual(json.loads(path.read_text()), {'next': 1})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.stat().st_nlink, 1)

    def test_publish_boundary_is_recorded_after_the_exclusive_link(self):
        path = self.root / 'journal.json'
        seen = []
        self.module.write_json(str(path), {}, exclusive=True, on_publish=lambda: seen.append(path.exists()))
        self.assertEqual(seen, [True])
        self.assertEqual(path.stat().st_nlink, 1)

    def test_collision_is_not_a_publication(self):
        path = self.root / 'journal.json'
        path.write_text('keep')
        seen = []
        with self.assertRaises(FileExistsError):
            self.module.write_json(str(path), {}, exclusive=True, on_publish=lambda: seen.append(True))
        self.assertEqual(seen, [])
        self.assertEqual(path.read_text(), 'keep')

    def test_directory_publish_never_replaces_an_existing_empty_directory(self):
        with self.module.directory(str(self.root)) as fd:
            os.mkdir('stage', dir_fd=fd)
            os.mkdir('destination', dir_fd=fd)
            before = os.stat('destination', dir_fd=fd).st_ino
            with self.assertRaises(OSError):
                self.module.native_directory_publish(fd, 'stage', 'destination')
            self.assertEqual(os.stat('destination', dir_fd=fd).st_ino, before)


class CapturedPreflightInputTests(unittest.TestCase):
    """The donor and canonical preflight must consume one captured registry."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_capture', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory(prefix='t13.preflight.', dir=os.environ.get('TMPDIR', '/tmp'))
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.workspace = self.base / 'workspace'
        self.home = self.base / 'home'
        self.root = self.base / 'project'
        self.journals = self.home / 'state/attachment-journals'
        for directory in (self.workspace, self.home, self.root, self.journals):
            directory.mkdir(parents=True, mode=0o700)
        self.registry = self.home / 'registry.json'
        self.original = b'{"schema_version":1,"projects":{}}\n'
        self.changed = b'{"schema_version":1,"projects":{"other":{}}}\n'
        self.registry.write_bytes(self.original)
        self.registry.chmod(0o600)
        self.diagnostic = self.original
        self.journal = self.journals / 'candidate.json'
        self.common = self.base / 'common'
        (self.common / 'info').mkdir(parents=True)
        self.exclude = self.common / 'info/exclude'
        self.exclude_bytes = b'fixture exclude\n'
        self.exclude.write_bytes(self.exclude_bytes)
        root_stat, common_stat = self.root.stat(), self.common.stat()
        self.root_pin = '%s:%s' % (root_stat.st_dev, root_stat.st_ino)
        common_pin = '%s:%s' % (common_stat.st_dev, common_stat.st_ino)
        self.plan = {'worktree_root': str(self.root), 'checkout_id': 'a' * 64,
                     'worktree_id': 'b' * 64, 'attachment_id': 'fixture'}
        self.argv = ['attach-fastpath.py', '--begin', str(self.workspace), str(self.home),
                     str(self.root), 'personal', 'fixture', json.dumps({'git_common_dir': str(self.common)}),
                     '1.2.3', '["claude"]', 'null', 'fixture', self.root_pin, common_pin, '123', '123', '123']
        self.prepared = (self.plan, str(self.base / 'owner.json'), str(self.journal),
                         str(self.base / 'authority.json'), str(self.base / 'donor.json'), [], {},
                         [self.workspace.stat(), self.registry.stat()])

    def child_path(self, argument):
        # The canonical child runs with the held workspace as its cwd.
        return self.workspace / argument

    def invoke(self, preflight, lock_state=None, prepare_impl=None, stdout=None):
        if lock_state is None:
            lock_state = {'held': True}
        def recheck():
            if not lock_state['held']:
                raise self.module.LostTransactionLock('injected lock loss')
        self.order = []
        @contextmanager
        def held_locks(*_args, **_kwargs):
            self.order.append('scope')
            try:
                yield SimpleNamespace(recheck=recheck, proof_infos=lambda: [])
            finally:
                recheck()
        # --begin prints its proposal digest; keep it out of the test log.
        with patch.object(sys, 'argv', self.argv), patch.object(sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(self.diagnostic))), \
             patch.object(sys, 'stdout', stdout if stdout is not None else io.StringIO()), \
             patch.object(self.module, 'require_private_lock_fds'), \
             patch.object(self.module, 'hold_publisher_lock', side_effect=lambda *args: self.order.append(('publisher', args))), \
             patch.object(self.module, 'transaction_lock_scope', side_effect=held_locks), \
             patch.object(self.module, 'prepare', side_effect=prepare_impl or (lambda *_args: self.prepared)), \
             patch.object(self.module.subprocess, 'run', side_effect=preflight):
            return self.module.main()

    def test_begin_prints_only_the_proposal_and_plan_digests(self):
        def preflight(argv, **_kwargs):
            self.child_path(argv[7]).write_text('{"b":1,"a":[2]}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        out = io.StringIO()
        self.assertEqual(self.invoke(preflight, stdout=out), 0)
        plan = self.module.json_bytes(self.prepared[0])
        self.assertEqual((self.workspace / 'plan.json').read_bytes(), plan)
        # H2: the attachment holder's publisher flock is held, for this
        # writer's life, before the lock scope captures its holders.
        self.assertEqual(self.order, [('publisher', (32, 123)), 'scope'])
        self.assertEqual(out.getvalue(), hashlib.sha256(b'{"a":[2],"b":1}').hexdigest() + ' '
                         + hashlib.sha256(plan).hexdigest() + '\n')

    def test_begin_miss_prints_no_digest(self):
        def preflight(argv, **_kwargs):
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=1, stderr=b'refused')
        out = io.StringIO()
        self.assertEqual(self.invoke(preflight, stdout=out), 10)
        self.assertEqual(out.getvalue(), '')

    def test_unchanged_capture_is_used_and_removed_after_preflight(self):
        seen = []
        def preflight(argv, **_kwargs):
            seen.append((self.child_path(argv[6]), self.child_path(argv[6]).read_bytes()))
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        self.assertEqual(self.invoke(preflight), 0)
        self.assertEqual(seen[0][1], self.original)
        self.assertNotEqual(seen[0][0], self.registry)
        self.assertFalse(seen[0][0].exists(), 'successful preflight left its capture behind')
        self.assertTrue(self.journal.exists())

    def test_donor_and_canonical_use_the_same_pinned_registry_capture(self):
        donor_bytes, canonical_bytes, live_reads, reads_at_prepare = [], [], [], []
        original_read = self.module.read_regular
        def read_regular(path, *args, **kwargs):
            if path == str(self.registry):
                live_reads.append(path)
            return original_read(path, *args, **kwargs)
        def prepare(*args):
            donor_bytes.append(args[13])  # registry_bytes
            reads_at_prepare.extend(live_reads)
            return self.prepared
        def preflight(argv, **_kwargs):
            canonical_bytes.append(self.child_path(argv[6]).read_bytes())
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        original_recheck = self.module.recheck_bound_file
        def recheck_bound_file(path, *args, **kwargs):
            if path == str(self.registry):
                live_reads.append(path)
            return original_recheck(path, *args, **kwargs)
        with patch.object(self.module, 'read_regular', side_effect=read_regular), \
             patch.object(self.module, 'recheck_bound_file', side_effect=recheck_bound_file):
            self.assertEqual(self.invoke(preflight, prepare_impl=prepare), 0)
        self.assertEqual(reads_at_prepare, [], 'donor took a separate live registry read')
        self.assertEqual(live_reads, [str(self.registry)], 'expected exactly one postflight re-read')
        self.assertEqual(donor_bytes, [self.original], 'donor did not consume the pinned capture')
        self.assertEqual(canonical_bytes, donor_bytes, 'donor and canonical registry bytes differ')

    def test_canonical_preflight_reads_the_donor_registry_bytes_during_live_aba(self):
        seen = []
        def preflight(argv, **_kwargs):
            # Model a non-cooperating writer between donor capture and the
            # canonical child, then restore the live file before postflight.
            self.registry.write_bytes(self.changed)
            seen.append(self.child_path(argv[6]).read_bytes())
            self.registry.write_bytes(self.original)
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        status = self.invoke(preflight)
        self.assertEqual(seen, [self.original], 'canonical preflight read a different registry from the donor')
        self.assertEqual(status, 10, 'live registry ABA must be a read-only miss')
        self.assertFalse(self.journal.exists(), 'a changed registry must not publish a journal')

    def test_workspace_ancestor_aba_cannot_swap_preflight_inputs(self):
        parent = self.base / 'workspace-parent'
        parent.mkdir(mode=0o700)
        self.workspace.rename(parent / 'workspace')
        self.workspace = parent / 'workspace'
        self.argv[2] = str(self.workspace)
        moved = self.base / 'workspace-parent.original'
        seen, by_name, arguments = [], [], []
        def preflight(argv, **kwargs):
            arguments.append(argv[6:9])
            parent.rename(moved)
            self.workspace.mkdir(parents=True, mode=0o700)
            forged = self.workspace / 'registry.captured.json'
            forged.write_bytes(self.changed)
            forged.chmod(0o600)
            by_name.append(forged.read_bytes())
            # A real child, started while the ancestor is swapped, reads its
            # input and writes its proposal exactly as the canonical one does.
            child = REAL_RUN(['/bin/sh', '-c', 'cat -- "$1" && printf "{}\\n" > "$2"', 'child', argv[6], argv[7]],
                             **dict(kwargs, stdout=subprocess.PIPE))
            seen.append(child.stdout)
            forged.unlink()
            for leftover in self.workspace.iterdir():
                leftover.unlink()
            self.workspace.rmdir()
            parent.rmdir()
            moved.rename(parent)
            return SimpleNamespace(returncode=child.returncode, stderr=b'')
        status = self.invoke(preflight)
        self.assertEqual(by_name, [self.changed], 'fixture did not redirect the workspace pathname')
        self.assertEqual(seen, [self.original], 'workspace ABA redirected the canonical child input')
        self.assertTrue(all(not os.path.isabs(path) for path in arguments[0]), 'child received absolute snapshot paths')
        self.assertEqual(status, 0, 'anchored child read the captured bytes')
        self.assertTrue(self.journal.exists())

    def test_donor_and_canonical_use_the_same_exclude_capture(self):
        donor, canonical, arguments = [], [], []
        def prepare(*args):
            donor.append(args[11])  # exclude_bytes
            return self.prepared
        def preflight(argv, **_kwargs):
            arguments.append(argv[11:13])
            canonical.append(self.child_path(argv[12]).read_bytes())
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        self.assertEqual(self.invoke(preflight, prepare_impl=prepare), 0)
        self.assertEqual(donor, [self.exclude_bytes], 'donor did not consume the exclude capture')
        self.assertEqual(canonical, donor, 'donor and canonical exclude bytes differ')
        self.assertEqual(arguments[0][0], str(self.exclude), 'child cannot check owner exclude paths')
        self.assertFalse(os.path.isabs(arguments[0][1]), 'child received an absolute exclude capture')
        self.assertFalse(self.child_path(arguments[0][1]).exists(), 'clean exclude capture was left behind')

    def test_live_exclude_aba_during_canonical_preflight_misses_before_journal(self):
        seen = []
        def preflight(argv, **_kwargs):
            self.exclude.write_bytes(b'other exclude\n')
            seen.append(self.child_path(argv[12]).read_bytes())
            self.exclude.write_bytes(self.exclude_bytes)
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        self.assertEqual(self.invoke(preflight), 10, 'live exclude ABA must be a read-only miss')
        self.assertEqual(seen, [self.exclude_bytes], 'canonical preflight read the live exclude')
        self.assertFalse(self.journal.exists())

    def test_owner_aba_during_canonical_preflight_misses_before_journal(self):
        owner_dir = self.base / 'owners'
        owner_dir.mkdir(mode=0o700)
        key = 'c' * 64
        owner = owner_dir / (key + '.json')
        owner.write_text('{"fixture":true}\n')
        owner.chmod(0o600)
        seen = []
        def prepare(*args):
            stack = args[12]  # owner_stack
            snapshots, infos = stack.enter_context(self.module.captured_owner_records(str(owner_dir), (key,)))
            return (self.plan, str(self.base / 'owner.json'), str(self.journal),
                    str(self.base / 'authority.json'), str(owner), [str(owner)], snapshots, infos)
        def preflight(argv, **_kwargs):
            seen.append(True)
            original = owner_dir / 'owner.original'
            owner.rename(original)
            owner.write_bytes(original.read_bytes())
            owner.chmod(0o600)
            os.replace(original, owner)
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        self.assertEqual(self.invoke(preflight, prepare_impl=prepare), 10)
        self.assertTrue(seen, 'canonical preflight did not reach the owner ABA seam')
        self.assertFalse(self.journal.exists())

    def test_replaced_captured_registry_is_a_miss_before_journal_publication(self):
        replaced = []
        def preflight(argv, **_kwargs):
            snapshot = self.child_path(argv[6])
            replacement = snapshot.with_name(snapshot.name + '.replacement')
            replacement.write_bytes(snapshot.read_bytes())
            replacement.chmod(0o600)
            os.replace(replacement, snapshot)
            replaced.append(snapshot)
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        status = self.invoke(preflight)
        self.assertEqual(status, 10, 'changed snapshot identity was accepted')
        self.assertFalse(self.journal.exists(), 'a miss must not publish a journal')
        self.assertTrue(replaced[0].exists(), 'unknown replacement must be retained')

    def test_symlinked_capture_is_retained_and_never_publishes(self):
        outside = self.base / 'outside'
        outside.write_text('preserve\n')
        def preflight(argv, **_kwargs):
            snapshot = self.child_path(argv[6])
            snapshot.unlink()
            snapshot.symlink_to(outside)
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        self.assertEqual(self.invoke(preflight), 10)
        self.assertFalse(self.journal.exists())
        self.assertTrue((self.workspace / 'registry.captured.json').is_symlink())
        self.assertEqual(outside.read_text(), 'preserve\n')

    def test_in_place_capture_change_is_retained_and_never_publishes(self):
        def preflight(argv, **_kwargs):
            self.child_path(argv[6]).write_bytes(self.changed)
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        self.assertEqual(self.invoke(preflight), 10)
        self.assertFalse(self.journal.exists())
        self.assertEqual((self.workspace / 'registry.captured.json').read_bytes(), self.changed)

    def test_live_registry_inode_swap_refuses_even_when_bytes_match(self):
        def preflight(argv, **_kwargs):
            replacement = self.registry.with_name('new-registry.json')
            replacement.write_bytes(self.original)
            replacement.chmod(0o600)
            os.replace(replacement, self.registry)
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        self.assertEqual(self.invoke(preflight), 10)
        self.assertFalse(self.journal.exists())
        self.assertEqual(self.registry.read_bytes(), self.original)

    def test_snapshot_swapped_before_first_name_check_is_a_read_only_miss(self):
        original_stat = os.stat
        swapped = []
        def stat_with_swap(path, *args, **kwargs):
            if path == 'registry.captured.json' and not swapped:
                parent = kwargs['dir_fd']
                name = '.replacement-before-pin'
                fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(self.original)
                os.replace(name, path, src_dir_fd=parent, dst_dir_fd=parent)
                swapped.append(True)
            return original_stat(path, *args, **kwargs)
        def preflight(argv, **_kwargs):
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        with patch.object(self.module.os, 'stat', side_effect=stat_with_swap):
            status = self.invoke(preflight)
        self.assertTrue(swapped, 'fixture did not swap the staging name')
        self.assertEqual(status, 10, 'unverified snapshot inode was accepted')
        self.assertFalse(self.journal.exists())
        self.assertTrue((self.workspace / 'registry.captured.json').exists(), 'unknown replacement must be retained')

    def ok_preflight(self, mutate=None):
        def preflight(argv, **_kwargs):
            self.child_path(argv[7]).write_text('{}\n')
            if mutate is not None:
                mutate()
            return SimpleNamespace(returncode=0, stderr=b'')
        return preflight

    def aliased_times(self):
        # A filesystem whose timestamps alias: an in-place, same-size rewrite
        # leaves every compared metadata field as captured.
        integrity = self.module.load_integrity()
        alias = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size)
        return patch.object(integrity, '_fingerprint', side_effect=alias)

    def test_coarse_clock_still_reuses_the_donor(self):
        # T13 D1: chmod that does not advance ctime (a coarse kernel clock)
        # no longer makes the fast path unavailable.
        with patch.object(self.module.os, 'fchmod', side_effect=lambda *_args: None):
            self.assertEqual(self.invoke(self.ok_preflight()), 0)
        self.assertTrue(self.journal.exists())

    def test_unsupported_filesystem_type_is_unavailable(self):
        stderr = io.StringIO()
        with patch.object(self.module, 'filesystem_type', return_value='nfs'), patch.object(sys, 'stderr', stderr):
            self.assertEqual(self.invoke(self.ok_preflight()), 10)
        self.assertFalse(self.journal.exists())
        self.assertIn('donor fast path unavailable here', stderr.getvalue())

    def test_live_exclude_rewritten_in_place_misses_even_with_aliased_times(self):
        def rewrite():
            with open(self.exclude, 'r+b') as stream:
                stream.write(b'fixture EXCLUDE\n')
        with self.aliased_times():
            self.assertEqual(self.invoke(self.ok_preflight(rewrite)), 10)
        self.assertFalse(self.journal.exists())

    def test_scratch_registry_copy_rewritten_in_place_misses_even_with_aliased_times(self):
        def rewrite():
            with open(self.workspace / 'registry.captured.json', 'r+b') as stream:
                stream.write(b'{"schema_version":2,"projects":{}}\n')
        with self.aliased_times():
            self.assertEqual(self.invoke(self.ok_preflight(rewrite)), 10)
        self.assertFalse(self.journal.exists())

    def test_registry_semantic_comparison_keeps_json_types(self):
        same = self.module.same_registry_snapshot
        self.assertTrue(same(b'{"a":1,"b":[true]}', b'{"b":[true],"a":1}'))
        self.assertFalse(same(b'{"a":true}', b'{"a":1}'))
        self.assertFalse(same(b'{"a":1}', b'{"a":2}'))
        self.assertFalse(same(b'{"a":1,"a":2}', b'{"a":2}'))
        self.assertFalse(same(b'{"a":1}\n{}', b'{"a":1}'))

    def test_lock_loss_during_preflight_refuses_before_journal(self):
        locks = {'held': True}
        def preflight(argv, **_kwargs):
            locks['held'] = False
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        self.assertEqual(self.invoke(preflight, locks), 3)
        self.assertFalse(self.journal.exists())

    def test_lock_loss_after_journal_is_a_recoverable_error(self):
        locks = {'held': True}
        original_write = self.module.write_json
        def write(path, *args, **kwargs):
            original_write(path, *args, **kwargs)
            if path == str(self.journal):
                locks['held'] = False
        def preflight(argv, **_kwargs):
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        with patch.object(self.module, 'write_json', side_effect=write):
            self.assertEqual(self.invoke(preflight, locks), 3)
        self.assertTrue(self.journal.is_file(), 'published journal must remain recoverable')

    def test_changed_diagnostic_snapshot_is_a_read_only_miss(self):
        self.diagnostic = self.changed
        seen = []
        def preflight(argv, **_kwargs):
            seen.append(True)
            self.child_path(argv[7]).write_text('{}\n')
            return SimpleNamespace(returncode=0, stderr=b'')
        self.assertEqual(self.invoke(preflight), 10)
        self.assertFalse(seen, 'canonical preflight ran on inconsistent snapshots')
        self.assertFalse(self.journal.exists())

class RegistryDonorAdmissionTests(unittest.TestCase):
    """Stage A: the first canonically valid candidate in the seed's registry
    order is admitted in one verifier pass; nothing else is attempted."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_admission', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.home, self.checkout, self.payload = '/h', 'c' * 64, '/h/releases/1.2.3/payload'
        self.owner_dir = self.home + '/state/attachments/' + self.checkout
        self.owners, self.snapshots, self.candidates = {}, {}, []
        for key, root in (('a' * 64, '/w/a'), ('b' * 64, '/w/b'), ('d' * 64, '/w/d')):
            record = {'checkout_id': self.checkout, 'worktree_id': key, 'worktree_root': root,
                      'attachment_id': 'att-' + key[0],
                      'artifacts': [{'path': '.trellis/runtime', 'kind': 'symlink', 'target': self.payload},
                                    {'path': '.claude/x.md', 'kind': 'file', 'sha256': '0' * 64}]}
            self.owners[key] = record
            self.snapshots[self.owner_dir + '/' + key + '.json'] = json.dumps(record).encode()
            self.candidates.append({'worktree_id': key, 'root': root, 'attachment_id': 'att-' + key[0]})
        self.schema = {path: True for path in self.snapshots}
        self.attempts, self.closed = [], []
        test = self
        class FakeNode:
            def __init__(self, path):
                self.kind, self.data, self.path = 'file', b'data:' + path.encode(), path
            def close(self):
                test.closed.append(self.path)
        def verify(home, entries, mode='verify', opener=None):
            [entry] = entries
            self.attempts.append(entry['path'])
            node = opener(None, 'x.md', 'file', {'path': '.claude/x.md'})
            self.assertTrue(entry['canonical'])
            return [{'owner': entry['path'], 'check': 'artifact'}] if entry['path'] in self.failing else []
        self.failing = set()
        self.module.owner_verify = SimpleNamespace(
            verify_owner_records=verify,
            capture_opener=lambda fd, name, kind, expected=None: FakeNode(expected['path']))

    def admit(self):
        stack = ExitStack()
        self.addCleanup(stack.close)
        return self.module.admit_registry_donor(self.home, self.owner_dir, self.checkout, self.candidates,
                                                self.owners, self.snapshots, self.schema, self.payload, stack)

    def path(self, key):
        return self.owner_dir + '/' + key + '.json'

    def test_first_valid_candidate_is_admitted_once_and_later_ones_are_not_tried(self):
        record, observed = self.admit()
        self.assertIs(record, self.owners['a' * 64])
        self.assertEqual(self.attempts, [self.path('a' * 64)])
        self.assertEqual(observed.data('.claude/x.md'), b'data:.claude/x.md')

    def test_drifted_candidate_is_skipped_in_registry_order(self):
        self.failing = {self.path('a' * 64)}
        record, observed = self.admit()
        self.assertIs(record, self.owners['b' * 64])
        self.assertEqual(self.attempts, [self.path('a' * 64), self.path('b' * 64)])
        # The refused candidate's observations are released at once.
        self.assertEqual(self.closed, ['.claude/x.md'])

    def test_candidates_that_fail_cheap_bindings_are_never_verified(self):
        self.schema[self.path('a' * 64)] = False
        self.owners['b' * 64]['artifacts'][0]['target'] = '/h/releases/9.9.9/payload'
        self.candidates[2]['root'] = '/w/elsewhere'
        self.assertEqual(self.admit(), (None, None))
        self.assertEqual(self.attempts, [])

    def test_no_valid_candidate_admits_nothing(self):
        self.failing = set(self.path(key) for key in self.owners)
        self.assertEqual(self.admit(), (None, None))
        self.assertEqual(len(self.attempts), 3)

    def test_unobserved_leaf_is_a_miss_not_a_reread(self):
        record, observed = self.admit()
        with self.assertRaises(ValueError):
            observed.data('.agents/never-verified.md')


class CapturedDonorFreshnessTests(unittest.TestCase):
    """r152-create-code F1: the admitted donor's captures are rechecked,
    without a second semantic pass, before their bytes are used and at the
    journal boundary. Any in-place change since the verifier saw them misses."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_fresh', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.module.load_owner_verify()
        self.tmp = tempfile.TemporaryDirectory(prefix='t13.fresh.', dir=os.environ.get('TMPDIR', '/tmp'))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / 'donor'
        (self.root / '.claude').mkdir(parents=True)
        (self.root / '.trellis').mkdir()
        self.render = self.root / '.claude/settings.json'
        self.render.write_text('{"owned":"value"}\n')
        (self.root / '.trellis/runtime').symlink_to('/payload')
        self.collector = self.module.Collector()
        self.addCleanup(self.collector.close)
        for path, kind in (('.claude', 'directory'), ('.claude/settings.json', 'file'), ('.trellis/runtime', 'symlink')):
            parent, name = os.path.split(str(self.root / path))
            fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                self.assertIsNotNone(self.collector.open(fd, name, kind, {'path': path}))
            finally:
                os.close(fd)
        self.collector.root = str(self.root)

    def test_same_size_rewrite_with_aliased_identity_misses(self):
        # T13 D1: identity can alias; the held bytes are compared in full.
        captured = {node.identity[1]: node.identity for node in self.collector.nodes.values()}
        parents = {node.parent_identity[1]: node.parent_identity for node in self.collector.nodes.values()}
        real = self.module.owner_verify._identity
        def aliased(info):
            return captured.get(info.st_ino) or parents.get(info.st_ino) or real(info)
        with open(self.render, 'r+b') as stream:
            stream.write(b'{"owned":"other"}'[:len(self.render.read_bytes()) - 1])
        with patch.object(self.module.owner_verify, '_identity', side_effect=aliased):
            with self.assertRaisesRegex(ValueError, 'bytes'):
                self.collector.require_fresh()

    def test_unchanged_captures_are_fresh(self):
        self.collector.require_fresh()

    def test_in_place_rewrite_keeping_the_inode_misses(self):
        inode = self.render.stat().st_ino
        with open(self.render, 'r+b') as stream:
            stream.write(b'{"owned":"other"}\n')
        self.assertEqual(self.render.stat().st_ino, inode)
        with self.assertRaises(ValueError):
            self.collector.require_fresh()

    def test_same_bytes_rewritten_still_miss(self):
        # Nonsemantic: the check never compares meaning, only identity.
        self.render.write_bytes(self.render.read_bytes())
        with self.assertRaises(ValueError):
            self.collector.require_fresh()

    def test_replaced_symlink_misses(self):
        link = self.root / '.trellis/runtime'
        link.unlink()
        link.symlink_to('/payload')
        with self.assertRaises(ValueError):
            self.collector.require_fresh()

    def test_parent_change_misses(self):
        (self.root / '.claude/new.json').write_text('{}\n')
        with self.assertRaises(ValueError):
            self.collector.require_fresh()

class FastPathUnavailableNoticeTests(unittest.TestCase):
    """T13 D3: an unavailable fast path says so once without TRACE; an
    ordinary donor miss stays quiet."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_notice', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def failure(self, error):
        stderr = io.StringIO()
        with patch.dict(os.environ, {}, clear=False), patch.object(sys, 'stderr', stderr):
            os.environ.pop('TRELLIS_FASTPATH_TRACE', None)
            status = self.module.finish_failure(error, '--begin', False, None)
        return status, stderr.getvalue()

    def test_unavailable_prints_one_notice_and_misses(self):
        status, text = self.failure(self.module.FastPathUnavailable('Claude Code version unreadable'))
        self.assertEqual(status, 10)
        self.assertEqual(text.splitlines(), ['trellis attach: donor fast path unavailable here (Claude Code version unreadable); running the full attach'])

    def test_only_allowlisted_local_filesystems_are_supported(self):
        fd = os.open('.', os.O_RDONLY)
        self.addCleanup(os.close, fd)
        for name in ('apfs', 'ext2/ext3/ext4', 'btrfs', 'xfs', 'tmpfs'):
            with patch.object(self.module, 'filesystem_type', return_value=name):
                self.module.require_supported_filesystem(fd)
        for name in ('nfs', 'smbfs', 'fuse', 'overlay', 'hfs', None):
            with self.subTest(name=name), patch.object(self.module, 'filesystem_type', return_value=name):
                with self.assertRaises(self.module.FastPathUnavailable):
                    self.module.require_supported_filesystem(fd)

    def test_this_machine_reports_a_filesystem_type(self):
        fd = os.open(os.environ.get('TMPDIR', '/tmp'), os.O_RDONLY)
        self.addCleanup(os.close, fd)
        self.assertIsInstance(self.module.filesystem_type(fd), str)

    def test_ordinary_miss_stays_quiet(self):
        status, text = self.failure(ValueError('no exact donor'))
        self.assertEqual((status, text), (10, ''))


class FinishProposalDigestTests(unittest.TestCase):
    """--finish trusts only the digests --begin held: the proposal it read
    through its workspace and the exact plan bytes it validated."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_finish', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory(prefix='t13.finish.', dir=os.environ.get('TMPDIR', '/tmp'))
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.workspace, self.home = base / 'workspace', base / 'home'
        for directory in (self.workspace, self.home):
            directory.mkdir(mode=0o700)
        plan = self.workspace / 'plan.json'
        plan.write_text(json.dumps({'checkout_id': 'a' * 64, 'worktree_id': 'b' * 64, 'attachment_id': 'fixture',
                                    'exclude': {'git_common_dir': str(base / 'common')}}))
        plan.chmod(0o600)
        self.plan_digest = hashlib.sha256(plan.read_bytes()).hexdigest()
        self.registry = self.home / 'registry.json'
        self.registry.write_bytes(b'{"projects": {"p": {"x": 1}}, "schema_version": 1}\n')
        self.registry.chmod(0o600)
        self.digest = hashlib.sha256(b'{"projects":{"p":{"x":1}},"schema_version":1}').hexdigest()

    def finish(self, digest, proposal=None, plan_digest=None, publish=None):
        self.stdout = io.StringIO()
        if plan_digest is None:
            plan_digest = self.plan_digest
        if proposal is not None:
            (self.workspace / 'registry.json').write_bytes(proposal)
        published, scopes = [], []
        self.events = []
        @contextmanager
        def held_scope(*args):
            scopes.append(args)
            scope = SimpleNamespace(recheck=lambda: None, release_checked=lambda: None, committed=False)
            def mark_committed():
                scope.committed = True
                self.events.append('committed')
            scope.mark_committed = mark_committed
            yield scope
        argv = ['attach-fastpath.py', '--finish', str(self.workspace), str(self.home), '1:1', '1:1', digest, plan_digest, '11', '12', '13']
        self.stderr = io.StringIO()
        with patch.object(sys, 'argv', argv), \
             patch.object(self.module, 'require_private_lock_fds'), \
             patch.object(self.module, 'hold_publisher_lock', side_effect=lambda *args: self.events.append(('publisher', args))), \
             patch.object(self.module, 'transaction_lock_scope', side_effect=held_scope), \
             patch.object(self.module, 'publish', side_effect=publish or (lambda *args: (published.append(args), self.events.append('published'), args[7]()))), \
             patch.object(sys, 'stdout', self.stdout), patch.object(sys, 'stderr', self.stderr):
            status = self.module.main()
        if published:
            # Publication ran inside the lock scope bound to begin's holders.
            self.assertEqual(scopes, [(str(self.home), {'checkout_id': 'a' * 64, 'worktree_id': 'b' * 64,
                                                        'git_common_dir': str(Path(self.tmp.name).resolve() / 'common')},
                                       'fixture', '11', '12', '13')])
        return status, published

    def test_matching_registry_publishes(self):
        status, published = self.finish(self.digest)
        self.assertEqual(status, 0, self.stderr.getvalue())
        self.assertEqual(len(published), 1)
        self.assertEqual(self.events, [('publisher', (32, 12)), 'published', 'committed'])

    def test_a_failure_after_the_commit_reports_committed(self):
        def commit_then_fail(*args):
            self.events.append('published')
            args[7]()
            raise ValueError('cleanup failed after the journal unlink')
        status, published = self.finish(self.digest, publish=commit_then_fail)
        self.assertEqual(status, 0, self.stderr.getvalue())
        self.assertTrue(self.stdout.getvalue().endswith('.json\n'), 'the committed owner path is still reported')
        self.assertNotIn('run trellis recover', self.stderr.getvalue())
        self.assertIn('committed', self.events)

    def test_refused_finish_never_marks_a_commit(self):
        status, published = self.finish(self.digest, plan_digest='0' * 64)
        self.assertEqual(status, 3)
        self.assertNotIn('committed', self.events)

    def test_forged_proposal_written_to_the_registry_refuses_recoverably(self):
        forged = b'{"projects":{"p":{"x":2}},"schema_version":1}\n'
        self.registry.write_bytes(forged)
        # The forged workspace proposal agrees with the registry; only the
        # begin digest can tell them apart.
        status, published = self.finish(self.digest, proposal=forged)
        self.assertEqual(status, 3)
        self.assertEqual(published, [])
        self.assertIn('registry API write differs from the begin proposal', self.stderr.getvalue())

    def test_malformed_digest_refuses(self):
        status, published = self.finish('not-a-digest')
        self.assertEqual(status, 3)
        self.assertEqual(published, [])

    def test_substituted_plan_refuses_recoverably(self):
        # H1: a coordinated plan-plus-journal substitution between --begin
        # and --finish must not publish; begin's plan digest is the authority.
        plan = self.workspace / 'plan.json'
        forged = json.loads(plan.read_text())
        forged['artifacts'] = [{'path': '.trellis/runtime', 'kind': 'symlink', 'target': 'unexpected'}]
        plan.write_text(json.dumps(forged))
        status, published = self.finish(self.digest)
        self.assertEqual(status, 3)
        self.assertEqual(published, [])
        self.assertIn('plan differs from the begin plan', self.stderr.getvalue())

    def test_malformed_plan_digest_refuses(self):
        status, published = self.finish(self.digest, plan_digest='not-a-digest')
        self.assertEqual(status, 3)
        self.assertEqual(published, [])


class FinishLockScopeTests(unittest.TestCase):
    """qp H3: --finish publishes and commits only under begin's exact locks."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_finish_locks', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory(prefix='t13.finish-locks.', dir=os.environ.get('TMPDIR', '/tmp'))
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.home, self.root = base / 'home', base / 'root'
        self.home.mkdir(mode=0o700)
        subprocess.run(['/usr/bin/git', 'init', '-q', str(self.root)], check=True)
        self.checkout = 'a' * 64
        self.managed = self.home / 'state/git-hooks' / self.checkout
        subprocess.run(['/usr/bin/git', '-C', str(self.root), 'config', '--local', 'core.hooksPath', str(self.managed)], check=True)
        self.plan = {'worktree_root': str(self.root), 'checkout_id': self.checkout, 'worktree_id': 'b' * 64,
                     'attachment_id': 'fixture', 'artifacts': [],
                     'exclude': {'git_common_dir': str(self.root / '.git')}}
        self.journal = self.home / 'state/attachment-journals/fixture.json'
        self.owner = self.home / 'state/attachments' / self.checkout / ('b' * 64 + '.json')
        for directory in (self.journal.parent, self.owner.parent):
            directory.mkdir(parents=True, mode=0o700)
        self.journal.write_text(json.dumps(dict(self.plan, phase=0, applied=[], pending=None, removal=None)))
        self.journal.chmod(0o600)
        self.pins = tuple(self.module.identity(os.stat(path)) for path in (self.root, self.root / '.git'))

    def publish(self, recheck):
        self.module.publish(self.plan, str(self.owner), str(self.journal), *self.pins, recheck)

    def test_lock_loss_before_the_owner_commit_keeps_the_journal(self):
        calls = []
        def recheck():
            calls.append(len(calls))
            # The first check passes; the lock is lost before the commit.
            if len(calls) > 1:
                raise self.module.LostTransactionLock('lock holder changed')
        with self.assertRaises(self.module.LostTransactionLock):
            self.publish(recheck)
        self.assertEqual(len(calls), 2)
        self.assertFalse(self.owner.exists())
        self.assertTrue(self.journal.exists())

    def test_lock_loss_after_the_owner_write_keeps_owner_and_journal(self):
        calls = []
        def recheck():
            calls.append(len(calls))
            # Both pre-commit namespace checks pass; the lock is lost once the
            # owner exists but before the journal is removed.
            if self.owner.exists():
                raise self.module.LostTransactionLock('lock holder changed')
        with self.assertRaises(self.module.LostTransactionLock):
            self.publish(recheck)
        self.assertTrue(self.owner.exists())
        self.assertTrue(self.journal.exists(), 'journal removed before the final lock check')

    def test_journal_directory_checks_finish_before_the_unlink(self):
        # r152-create-code F3: once the journal is gone the transaction is
        # committed; no journal-directory context check may run after it.
        real_unlink = os.unlink
        journal_dir = self.journal.parent
        def unlink(name, *args, **kwargs):
            real_unlink(name, *args, **kwargs)
            if name == self.journal.name:
                journal_dir.rename(journal_dir.with_name('journals-moved'))
                journal_dir.mkdir(mode=0o700)
        with patch.object(self.module.os, 'unlink', side_effect=unlink):
            self.publish(lambda: None)
        self.assertTrue(self.owner.exists())
        self.assertFalse((journal_dir.with_name('journals-moved') / self.journal.name).exists())

    def test_held_locks_commit(self):
        calls = []
        self.publish(lambda: calls.append(1))
        self.assertGreaterEqual(len(calls), 2)
        self.assertTrue(self.owner.exists())
        self.assertFalse(self.journal.exists())


class CapturedOwnerRecordTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_owner_capture', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory(prefix='t13.owners.', dir=os.environ.get('TMPDIR', '/tmp'))
        self.addCleanup(self.tmp.cleanup)
        self.owner_dir = Path(self.tmp.name).resolve() / 'owners'
        self.owner_dir.mkdir(mode=0o700)
        self.keys = ('a' * 64, 'b' * 64)
        self.expected = {}
        for key in self.keys:
            path = self.owner_dir / (key + '.json')
            data = ('{"worktree_id":"' + key + '"}\n').encode()
            path.write_bytes(data)
            path.chmod(0o600)
            self.expected[str(path)] = data

    def capture(self):
        return self.module.captured_owner_records(str(self.owner_dir), self.keys)

    def test_all_owner_records_are_one_held_capture(self):
        with self.capture() as (records, infos):
            self.assertEqual(records, self.expected)
            self.assertEqual(len(infos), len(self.keys) + 1)
            self.assertTrue(all(info.st_dev == self.owner_dir.stat().st_dev for info in infos))

    def test_equal_byte_owner_replacement_and_restore_refuses(self):
        path = self.owner_dir / (self.keys[0] + '.json')
        original = self.owner_dir / 'original'
        with self.assertRaises(ValueError):
            with self.capture():
                path.rename(original)
                path.write_bytes(self.expected[str(path)])
                path.chmod(0o600)
                os.replace(original, path)

    def test_in_place_owner_content_aba_refuses(self):
        path = self.owner_dir / (self.keys[0] + '.json')
        with self.assertRaises(ValueError):
            with self.capture():
                path.write_text('{"changed":true}\n')
                path.write_bytes(self.expected[str(path)])

    def test_owner_directory_membership_aba_refuses(self):
        foreign = self.owner_dir / 'foreign.json'
        with self.assertRaises(ValueError):
            with self.capture():
                foreign.write_text('{}\n')
                foreign.unlink()

    def test_unexpected_or_symlink_owner_never_enters_capture(self):
        (self.owner_dir / 'unexpected').write_text('foreign\n')
        with self.assertRaises(ValueError):
            with self.capture():
                pass
        (self.owner_dir / 'unexpected').unlink()
        target = self.owner_dir / (self.keys[0] + '.json')
        target.unlink()
        target.symlink_to(self.owner_dir / (self.keys[1] + '.json'))
        with self.assertRaises((ValueError, OSError)):
            with self.capture():
                pass


class CapturedExcludeRecordTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_exclude_capture', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.module.load_integrity()
        self.tmp = tempfile.TemporaryDirectory(prefix='t13.exclude.', dir=os.environ.get('TMPDIR', '/tmp'))
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.common = base / 'common'
        (self.common / 'info').mkdir(parents=True)
        self.workspace = base / 'workspace'
        self.workspace.mkdir(mode=0o700)
        self.exclude = self.common / 'info/exclude'
        self.original = b'fixture exclude\n'
        self.exclude.write_bytes(self.original)
        info = self.common.stat()
        self.common_pin = '%d:%d' % (info.st_dev, info.st_ino)

    @contextmanager
    def capture(self, common_pin=None):
        with self.module.directory(str(self.workspace)) as scratch_fd:
            with self.module.captured_shared_exclude(scratch_fd, str(self.common), common_pin or self.common_pin) as result:
                yield result

    def test_captures_the_exact_exclude_into_a_private_relative_copy(self):
        with self.capture() as (data, name, infos):
            self.assertEqual(data, self.original)
            self.assertFalse(os.path.isabs(name))
            self.assertEqual((self.workspace / name).read_bytes(), self.original)
            self.assertEqual(infos[0].st_ino, self.exclude.stat().st_ino)
            self.assertEqual(infos[1].st_ino, (self.workspace / name).stat().st_ino)
        self.assertEqual(list(self.workspace.iterdir()), [], 'clean capture was not removed')

    def test_in_place_exclude_aba_refuses(self):
        with self.assertRaises(ValueError):
            with self.capture():
                self.exclude.write_bytes(b'other exclude\n')
                self.exclude.write_bytes(self.original)

    def test_equal_byte_exclude_replacement_and_restore_refuses(self):
        old = self.exclude.with_name('original')
        with self.assertRaises(ValueError):
            with self.capture():
                self.exclude.rename(old)
                self.exclude.write_bytes(self.original)
                os.replace(old, self.exclude)

    def test_changed_private_copy_refuses_and_is_retained(self):
        with self.assertRaises(ValueError):
            with self.capture() as (_data, name, _infos):
                (self.workspace / name).write_bytes(b'other exclude\n')
        self.assertEqual((self.workspace / name).read_bytes(), b'other exclude\n')

    def test_replaced_common_directory_refuses(self):
        with self.assertRaises(ValueError):
            with self.capture(common_pin='0:0'):
                pass
        self.assertEqual(list(self.workspace.iterdir()), [])

    def test_symlinked_exclude_refuses(self):
        other = self.exclude.with_name('other')
        self.exclude.rename(other)
        self.exclude.symlink_to(other)
        with self.assertRaises((ValueError, OSError)):
            with self.capture():
                pass

    def test_symlinked_info_directory_refuses(self):
        real = self.common / 'real-info'
        (self.common / 'info').rename(real)
        (self.common / 'info').symlink_to(real)
        with self.assertRaises((ValueError, OSError)):
            with self.capture():
                pass


class TransactionLockPinTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_locks', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory(prefix='t13.locks.', dir=os.environ.get('TMPDIR', '/tmp'))
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve() / 'home'
        self.state_locks = self.home / 'state/locks'
        self.registry_locks = self.home / 'locks'
        self.state_locks.mkdir(parents=True, mode=0o700)
        self.registry_locks.mkdir(parents=True, mode=0o700)
        self.checkout = 'a' * 64
        self.worktree = 'b' * 64
        self.common = str(self.home / 'common')
        self.attachment = '12345678-1234-4123-8123-123456789abc'
        self.pid = os.getpid()
        self.binding = {'checkout_id': self.checkout, 'worktree_id': self.worktree, 'git_common_dir': self.common}
        self.checkout_link = self.state_locks / ('attachment-checkout-' + self.checkout + '.lock')
        self.attachment_link = self.state_locks / ('attachment-' + self.checkout + '-' + self.worktree + '.lock')
        self.checkout_holder = self.state_locks / ('.attachment-checkout-' + self.checkout + '.holder-test')
        self.attachment_holder = self.state_locks / ('.attachment-' + self.checkout + '-' + self.worktree + '.holder-test')
        self.registry_holder = self.registry_locks / 'registry.lock'
        for path in (self.checkout_holder, self.attachment_holder, self.registry_holder):
            path.mkdir(mode=0o700)
        self.checkout_link.symlink_to(self.checkout_holder.name)
        self.attachment_link.symlink_to(self.attachment_holder.name)
        self.checkout_token = {'checkout_id': self.checkout, 'git_common_dir': self.common,
                               'pid': self.pid, 'process_birth': 'test-birth'}
        self.attachment_token = {'checkout_id': self.checkout, 'worktree_id': self.worktree,
                                 'attachment_id': self.attachment, 'pid': self.pid, 'process_birth': 'test-birth'}
        for path, value in ((self.checkout_holder / 'owner.json', self.checkout_token),
                            (self.attachment_holder / 'owner.json', self.attachment_token)):
            path.write_text(json.dumps(value) + '\n')
            path.chmod(0o600)
        (self.registry_holder / 'pid').write_text(str(self.pid) + '\n')
        (self.registry_holder / 'pid').chmod(0o600)
        self.fds = tuple(os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                         for path in (self.checkout_holder, self.attachment_holder, self.registry_holder))
        for fd in self.fds:
            self.addCleanup(os.close, fd)

    def scope(self):
        return self.module.transaction_lock_scope(str(self.home), self.binding, self.attachment,
                                                  self.pid, self.pid, self.pid, self.fds)

    def test_unrelated_fds_are_closed_inside_the_helper(self):
        program = '''import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fastpath_child", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.require_private_lock_fds((31, 32, 33))
for fd in (3, 4):
    try:
        os.fstat(fd)
    except OSError:
        continue
    raise SystemExit("extraneous fd remained open: %d" % fd)
for fd in (31, 32, 33):
    os.fstat(fd)
'''
        script = ('exec 3<"$1" 4<"$1" 31<"$2" 32<"$3" 33<"$4"; '
                  'exec /usr/bin/python3 -I -c "$6" "$5"')
        result = subprocess.run(['/bin/bash', '-c', script, 't13', str(self.registry_holder / 'pid'),
                                 str(self.checkout_holder), str(self.attachment_holder),
                                 str(self.registry_holder), str(LIB / 'attach-fastpath.py'), program],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_begin_sanitizes_inherited_fds_before_loading_the_verifier(self):
        events = []
        def stop_at_verifier():
            events.append('load')
            raise ValueError('stop after entry')
        with patch.object(sys, 'argv', ['attach-fastpath.py', '--begin', str(self.home)]), \
             patch.object(self.module, 'require_private_lock_fds', side_effect=lambda fds: events.append(('sanitize', fds))), \
             patch.object(self.module, 'load_integrity', side_effect=stop_at_verifier):
            self.assertEqual(self.module.main(), 10)
        self.assertEqual(events, [('sanitize', (31, 32, 33)), 'load'])

    def test_unchanged_lock_set_rechecks(self):
        with self.scope() as scope:
            scope.recheck()

    def test_unrelated_preflight_miss_is_not_misclassified_as_lock_loss(self):
        with self.assertRaisesRegex(ValueError, 'historical shape'):
            with self.scope():
                raise ValueError('historical shape')

    def test_equal_token_holder_replacement_before_start_refuses(self):
        self.attachment_holder.rename(self.attachment_holder.with_name(self.attachment_holder.name + '.old'))
        self.attachment_holder.mkdir(mode=0o700)
        (self.attachment_holder / 'owner.json').write_text(json.dumps(self.attachment_token) + '\n')
        (self.attachment_holder / 'owner.json').chmod(0o600)
        with self.assertRaises(self.module.LostTransactionLock):
            with self.scope():
                pass

    def test_alias_loss_and_token_replacement_during_scope_refuse(self):
        with self.assertRaises(self.module.LostTransactionLock):
            with self.scope() as scope:
                self.checkout_link.unlink()
                self.checkout_link.symlink_to(self.checkout_holder.name + '.other')
                scope.recheck()

    def test_token_change_during_scope_refuses(self):
        with self.assertRaises(self.module.LostTransactionLock):
            with self.scope() as scope:
                (self.registry_holder / 'pid').write_text('999999\n')
                scope.recheck()

    def publisher_busy(self):
        # The canonical recovery probe, _attachment_publisher_idle.
        probe = ('import fcntl, os, sys\n'
                 'fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW)\n'
                 'try:\n    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n'
                 'except BlockingIOError:\n    sys.exit(3)\n')
        result = subprocess.run([sys.executable, '-I', '-c', probe, str(self.attachment_holder / 'publisher.lock')])
        return result.returncode == 3

    def test_publisher_lock_keeps_recovery_out_and_precedes_the_holder_capture(self):
        fd = self.module.hold_publisher_lock(self.fds[1], self.pid)
        try:
            self.assertTrue(self.publisher_busy(), 'recovery could reclaim a lock whose writer is alive')
            # Creating it changed the holder; the scope captured afterwards holds.
            with self.scope() as scope:
                scope.recheck()
        finally:
            os.close(fd)
        # The writer's exit frees it for recovery.
        self.assertFalse(self.publisher_busy())

    def test_publisher_lock_held_elsewhere_refuses(self):
        fd = self.module.hold_publisher_lock(self.fds[1], self.pid)
        try:
            child = subprocess.run([sys.executable, '-I', '-c', (
                'import importlib.util, os, sys\n'
                'spec = importlib.util.spec_from_file_location("fp", sys.argv[1])\n'
                'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n'
                'fd = os.open(sys.argv[2], os.O_RDONLY | os.O_DIRECTORY)\n'
                'try:\n    m.hold_publisher_lock(fd, os.getpid())\n'
                'except m.LostTransactionLock:\n    sys.exit(7)\n'), str(LIB / 'attach-fastpath.py'), str(self.attachment_holder)])
        finally:
            os.close(fd)
        self.assertEqual(child.returncode, 7)

    def test_publisher_lock_refuses_a_dead_lock_owner(self):
        dead = subprocess.Popen([sys.executable, '-c', 'pass'])
        dead.wait()
        with self.assertRaises(self.module.LostTransactionLock):
            self.module.hold_publisher_lock(self.fds[1], dead.pid)

    def test_publisher_lock_refuses_a_reclaimed_holder(self):
        (self.attachment_holder / 'owner.json').unlink()
        self.attachment_link.unlink()
        self.attachment_holder.rmdir()
        with self.assertRaises(self.module.LostTransactionLock):
            self.module.hold_publisher_lock(self.fds[1], self.pid)

    def test_publisher_lock_refuses_a_symlink(self):
        (self.attachment_holder / 'publisher.lock').symlink_to(self.attachment_holder / 'owner.json')
        with self.assertRaises(self.module.LostTransactionLock):
            self.module.hold_publisher_lock(self.fds[1], self.pid)

    def test_publisher_lock_refuses_a_fifo_without_blocking(self):
        # F4: a FIFO with no reader must not block the open; the type check
        # refuses it, in a bounded child so a hang fails instead of stalling.
        os.mkfifo(self.attachment_holder / 'publisher.lock', 0o600)
        child = subprocess.run([sys.executable, '-I', '-c', (
            'import importlib.util, os, sys\n'
            'spec = importlib.util.spec_from_file_location("fp", sys.argv[1])\n'
            'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n'
            'fd = os.open(sys.argv[2], os.O_RDONLY | os.O_DIRECTORY)\n'
            'try:\n    m.hold_publisher_lock(fd, os.getpid())\n'
            'except m.LostTransactionLock:\n    sys.exit(7)\n'), str(LIB / 'attach-fastpath.py'), str(self.attachment_holder)],
            timeout=10)
        self.assertEqual(child.returncode, 7)

    def swap_lock_parent(self):
        moved = self.state_locks.with_name('locks-moved')
        self.state_locks.rename(moved)
        self.state_locks.mkdir(mode=0o700)

    def test_lock_parent_checks_finish_before_the_commit(self):
        # r152-create-code F3: the lock-parent contexts unwind, with their
        # checks, before the journal unlink; after the commit the scope's exit
        # only closes resources.
        with self.scope() as scope:
            scope.release_checked()
            scope.mark_committed()
            self.swap_lock_parent()

    def test_committed_scope_unwind_never_reports_a_lock_loss(self):
        # Even without the early unwind, a committed scope's remaining
        # lock-parent context exits cannot turn the commit into a lock loss.
        with self.scope() as scope:
            scope.mark_committed()
            self.swap_lock_parent()

    def test_lock_parent_change_before_the_commit_is_a_lock_loss(self):
        with self.assertRaises(self.module.LostTransactionLock):
            with self.scope() as scope:
                self.swap_lock_parent()
                scope.release_checked()

    def test_replaced_publisher_lock_name_is_a_lock_loss(self):
        # Sol r152-t13-design-2 F1: the name must still bind the flocked inode.
        fd = self.module.hold_publisher_lock(self.fds[1], self.pid)
        self.addCleanup(os.close, fd)
        lock = self.attachment_holder / 'publisher.lock'
        # Sol's model: the holder directory's times alias (coarse clock and a
        # step back), so only the name-to-inode binding can tell.
        integrity = self.module.load_integrity()
        alias = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink)
        with patch.object(integrity, '_fingerprint', side_effect=alias), self.assertRaises(self.module.LostTransactionLock):
            with self.scope() as scope:
                scope.publisher_fd = fd
                scope.recheck()
                lock.unlink()
                lock.write_text('')
                lock.chmod(0o600)
                scope.recheck()

    def test_bound_publisher_lock_rechecks_clean(self):
        fd = self.module.hold_publisher_lock(self.fds[1], self.pid)
        self.addCleanup(os.close, fd)
        with self.scope() as scope:
            scope.publisher_fd = fd
            scope.recheck()

    def test_uncommitted_scope_exit_still_detects_lock_loss(self):
        with self.assertRaises(self.module.LostTransactionLock):
            with self.scope():
                (self.registry_holder / 'pid').write_text('999999\n')

    def test_committed_scope_exit_cannot_reclaim_the_committed_transaction(self):
        # After the journal is removed, no later fallible check may report an
        # uncommitted transaction: the exit recheck stops at the commit.
        with self.scope() as scope:
            scope.mark_committed()
            (self.registry_holder / 'pid').write_text('999999\n')

    def test_lock_parent_replacement_is_detected_at_each_recheck(self):
        for parent in (self.state_locks, self.registry_locks):
            with self.subTest(parent=parent):
                moved = parent.with_name(parent.name + '.moved')
                caught_at_recheck = False
                try:
                    with self.assertRaises(self.module.LostTransactionLock):
                        with self.scope() as scope:
                            parent.rename(moved)
                            parent.mkdir(mode=0o700)
                            try:
                                scope.recheck()
                            except self.module.LostTransactionLock:
                                caught_at_recheck = True
                                raise
                finally:
                    if moved.exists():
                        parent.rmdir()
                        moved.rename(parent)
                self.assertTrue(caught_at_recheck, 'lock loss was detected only after the journal boundary')


class LockPinBenchTests(unittest.TestCase):
    def setUp(self):
        self.script = Path(__file__).parent / 'helpers/bench-attach-lock-pins.py'
        spec = importlib.util.spec_from_file_location('lock_pin_bench', self.script)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_rotation_covers_each_arm_at_each_position(self):
        orders = [self.module.arm_order(i) for i in range(5)]
        for order in orders:
            self.assertEqual(set(order), set(self.module.ARMS))
        for position in range(5):
            self.assertEqual({order[position] for order in orders}, set(self.module.ARMS))

    def test_functional_mode_never_reads_a_clock_or_load(self):
        rows = []
        with patch.object(self.module.time, 'perf_counter_ns', side_effect=AssertionError('clock read')), \
             patch.object(self.module.os, 'getloadavg', side_effect=AssertionError('load read')):
            self.module.run_samples(lambda _arm: None, rows.append, measured=False, samples=1, warmups=0, load_limit=2)
        self.assertEqual({row['arm'] for row in rows}, set(self.module.ARMS))
        self.assertTrue(all(row['elapsed_ms'] is None and row['load_before'] is None for row in rows))

    def test_measurement_boundaries_exclude_verification_and_log_writes(self):
        events, rows = [], []
        ticks = iter((1_000_000, 2_000_000) * len(self.module.ARMS))
        def clock():
            events.append('clock')
            return next(ticks)
        def quiet():
            events.append('quiet')
            return [0.1, 0.1, 0.1], {'state': 'CLEAR', 'matches': []}
        def run(arm):
            events.append('run')
            return arm
        def verify(_arm, _result):
            events.append('verify')
        def record(row):
            events.append('record')
            rows.append(row)
        with patch.object(self.module.time, 'perf_counter_ns', side_effect=clock), \
             patch.object(self.module, 'quiet_state', side_effect=quiet):
            self.module.run_samples(run, record, measured=True, samples=1, warmups=0, load_limit=2, verify=verify)
        self.assertEqual(events[:7], ['quiet', 'clock', 'run', 'clock', 'verify', 'quiet', 'record'])
        self.assertEqual(len(rows), 5)
        self.assertTrue(all(row['elapsed_ms'] == 1 for row in rows))

    def test_busy_after_a_sample_is_recorded_and_refuses_further_work(self):
        rows = []
        states = [([0.1, 0, 0], {'state': 'CLEAR', 'matches': []}),
                  ([2.1, 0, 0], {'state': 'CLEAR', 'matches': []}),
                  ([2.1, 0, 0], {'state': 'CLEAR', 'matches': []})]
        with patch.object(self.module.time, 'perf_counter_ns', side_effect=[1, 2]), \
             patch.object(self.module, 'quiet_state', side_effect=states) as quiet:
            with self.assertRaisesRegex(RuntimeError, 'host not quiet'):
                self.module.run_samples(lambda _arm: None, rows.append, measured=True,
                                        samples=1, warmups=0, load_limit=2)
        self.assertEqual(quiet.call_count, 2, 'continued to another arm after busy postflight')
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['load_after'][0], 2.1)

    def test_summary_excludes_warmups_and_reports_paired_differences(self):
        rows = []
        for round_number in range(32):
            for index, arm in enumerate(self.module.ARMS):
                value = 999999 if round_number < 2 else round_number + index
                rows.append({'round': round_number, 'arm': arm, 'warmup': round_number < 2,
                             'elapsed_ms': value})
        summary = self.module.summarize(rows)
        self.assertEqual(summary['full']['count'], 30)
        self.assertEqual(summary['full']['within_round_difference_from_baseline']['p50_ms'], 4)
        self.assertLess(summary['full']['absolute']['p90_ms'], 100)

    def test_recheck_count_drift_refuses_the_benchmark(self):
        with tempfile.TemporaryDirectory(prefix='t13.lockbench.source.', dir=os.environ.get('TMPDIR', '/tmp')) as temp:
            path = Path(temp) / 'source.py'
            scope = 'def transaction_lock_scope():\n' + '    scope.recheck()\n' * 2
            path.write_text('def main():\n' + '    locks.recheck()\n' * 4 + scope)
            self.assertEqual(self.module.validate_recheck_count(path), 4)
            path.write_text('def main():\n' + '    locks.recheck()\n' * 5 + scope)
            with self.assertRaisesRegex(ValueError, 'recheck count changed'):
                self.module.validate_recheck_count(path)
            path.write_text('def main():\n' + '    locks.recheck()\n' * 4 + scope.replace('    scope.recheck()\n', '', 1))
            with self.assertRaisesRegex(ValueError, 'recheck count changed'):
                self.module.validate_recheck_count(path)

    def test_timing_requires_explicit_liveness_and_at_least_thirty_samples(self):
        self.module.validate_run(False, 1, False)
        with self.assertRaises(ValueError):
            self.module.validate_run(True, 29, True)
        with self.assertRaises(ValueError):
            self.module.validate_run(True, 30, False)
        self.module.validate_run(True, 30, True)

    def test_probe_refuses_a_missing_requested_pin(self):
        common = [str(LIB / 'attach-fastpath.py'), '/fixture', '/fixture', 'a' * 64, 'b' * 64,
                  '12345678-1234-4123-8123-123456789abc', str(os.getpid()), str(os.getpid()), str(os.getpid())]
        baseline = subprocess.run([sys.executable, '-I', '-c', self.module.PROBE, 'baseline', *common],
                                  capture_output=True, text=True)
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        missing = subprocess.run([sys.executable, '-I', '-c', self.module.PROBE, 'checkout-pin', *common],
                                 capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0, 'probe accepted a missing checkout pin')

    def test_cli_refuses_unapproved_or_incomplete_measurement(self):
        with tempfile.TemporaryDirectory(prefix='t13.lockbench.refuse.') as temp:
            repo = Path(__file__).resolve().parents[2]
            for index, options in enumerate((
                ['--samples', '30', '--candidate', 'a' * 40],
                ['--samples', '29', '--candidate', 'a' * 40, '--liveness-clear'],
                ['--samples', '30', '--candidate', 'short', '--liveness-clear'],
                ['--samples', '30', '--candidate', 'a' * 40, '--warmups', '1', '--liveness-clear'],
            )):
                output = Path(temp) / ('run-' + str(index))
                result = subprocess.run([sys.executable, '-I', str(self.script), '--repo', str(repo),
                                         '--output', str(output), '--measure', *options], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, options)
                self.assertFalse(output.exists(), 'a refused measurement started a fixture')

    def test_functional_cli_checks_real_lock_protocol_without_timing(self):
        with tempfile.TemporaryDirectory(prefix='t13.lockbench.') as temp:
            output = Path(temp) / 'run'
            repo = Path(__file__).resolve().parents[2]
            result = subprocess.run([sys.executable, '-I', str(self.script), '--repo', str(repo),
                                     '--output', str(output), '--functional'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads((output / 'summary.json').read_text())
            self.assertEqual(summary['mode'], 'functional')
            self.assertEqual(set(summary['arms']), set(self.module.ARMS))
            self.assertTrue(all(row['elapsed_ms'] is None for row in summary['observations']))
            self.assertFalse(any((output / 'trellis' / 'state/locks').iterdir()))
            self.assertFalse(any((output / 'trellis' / 'locks').iterdir()))


class IncrementalBenchBaselineTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('incremental_bench', Path(__file__).parent / 'helpers/bench-attach-incremental.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_default_baseline_is_pinned_instead_of_following_head(self):
        with patch.object(self.module, 'run', return_value='resolved-commit\n') as command:
            self.assertEqual(self.module.resolve_baseline(Path('/fixture/repo')), 'resolved-commit')
        command.assert_called_once_with(['git', '-C', '/fixture/repo', 'rev-parse', '--verify', '2f101f0d^{commit}'])

    def test_explicit_baseline_is_resolved_and_recordable(self):
        with patch.object(self.module, 'run', return_value='other-commit\n') as command:
            self.assertEqual(self.module.resolve_baseline(Path('/fixture/repo'), 'fixture-base'), 'other-commit')
        command.assert_called_once_with(['git', '-C', '/fixture/repo', 'rev-parse', '--verify', 'fixture-base^{commit}'])


class BenchSummaryTests(unittest.TestCase):
    def test_n5_nearest_rank_p95(self):
        spec = importlib.util.spec_from_file_location('bench', Path(__file__).parent / 'helpers/bench-attach-fastpath.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.summarize([5, 1, 4, 2, 3]), {'n': 5, 'p50_ms': 3, 'p95_ms': 5})



class ExclusivePublishTests(unittest.TestCase):
    """T39: a link the filesystem cannot make (HFS+ symlinks: ENOTSUP) falls
    back to an exclusive, inode-keeping rename; any other failure refuses."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_publish', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.fd = os.open(self.tmp.name, os.O_RDONLY | os.O_DIRECTORY)

    def tearDown(self):
        os.close(self.fd)
        self.tmp.cleanup()

    def unsupported_link(self, code):
        def link(*args, **kwargs):
            raise OSError(code, os.strerror(code))
        return patch.object(self.module.os, 'link', side_effect=link)

    def test_unsupported_link_publishes_by_exclusive_rename(self):
        import errno
        with self.unsupported_link(errno.ENOTSUP):
            self.module.write_json_at(self.fd, 'record.json', {'a': 1}, exclusive=True)
        self.assertEqual(json.loads(Path(self.tmp.name, 'record.json').read_text()), {'a': 1})
        self.assertEqual([n for n in os.listdir(self.tmp.name) if '.fast-' in n], [])

    def test_exclusive_rename_never_replaces_and_keeps_the_inode(self):
        import errno
        os.symlink('target', 'stage', dir_fd=self.fd)
        inode = os.stat('stage', dir_fd=self.fd, follow_symlinks=False).st_ino
        self.module.exclusive_rename_at(self.fd, 'stage', 'published')
        self.assertEqual(os.stat('published', dir_fd=self.fd, follow_symlinks=False).st_ino, inode)
        os.symlink('other', 'stage2', dir_fd=self.fd)
        with self.assertRaises(OSError) as raised:
            self.module.exclusive_rename_at(self.fd, 'stage2', 'published')
        self.assertEqual(raised.exception.errno, errno.EEXIST)
        self.assertEqual(os.readlink('published', dir_fd=self.fd), 'target')

    def test_other_link_failures_still_refuse(self):
        import errno
        with self.unsupported_link(errno.EPERM):
            with self.assertRaises(OSError) as raised:
                self.module.write_json_at(self.fd, 'record.json', {'a': 1}, exclusive=True)
        self.assertEqual(raised.exception.errno, errno.EPERM)
        self.assertFalse(os.path.exists(Path(self.tmp.name, 'record.json')))
        with self.unsupported_link(errno.ENOTSUP):
            Path(self.tmp.name, 'taken.json').write_text('{}')
            with self.assertRaises(OSError) as raised:
                self.module.write_json_at(self.fd, 'taken.json', {'a': 1}, exclusive=True)
            self.assertEqual(raised.exception.errno, errno.EEXIST)
            self.assertEqual(Path(self.tmp.name, 'taken.json').read_text(), '{}')



class PriorHooksStateTests(unittest.TestCase):
    """r152-create-3 M1: the prior hooks fact changes whenever the shell's
    passthrough-shim predicates can change, an ACL-only execute change too."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location('fastpath_prior_hooks', LIB / 'attach-fastpath.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.prior = os.path.join(self.tmp.name, 'hooks')
        os.mkdir(self.prior, 0o700)
        self.hook = os.path.join(self.prior, 'pre-commit')
        Path(self.hook).write_text('#!/bin/sh\nexit 0\n')
        os.chmod(self.hook, 0o700)

    def test_mode_and_new_entries_change_the_state(self):
        before = self.module.prior_hooks_state(self.prior)
        os.chmod(self.hook, 0o600)
        self.assertNotEqual(before, self.module.prior_hooks_state(self.prior))
        os.chmod(self.hook, 0o700)
        self.assertEqual(before, self.module.prior_hooks_state(self.prior))
        Path(self.prior, 'commit-msg').write_text('')
        self.assertNotEqual(before, self.module.prior_hooks_state(self.prior))

    def test_an_execute_answer_change_alone_changes_the_state(self):
        # Same stat (an ACL deny-execute leaves mode and owner as they are):
        # only the effective execute answer differs.
        real_access = os.access
        before = self.module.prior_hooks_state(self.prior)
        def denied(path, mode, *args, **kwargs):
            if path == self.hook and mode == os.X_OK:
                return False
            return real_access(path, mode, *args, **kwargs)
        with patch.object(self.module.os, 'access', denied):
            self.assertNotEqual(before, self.module.prior_hooks_state(self.prior))
        self.assertEqual(before, self.module.prior_hooks_state(self.prior))

    def test_an_unreadable_directory_answer_changes_the_state(self):
        real_access = os.access
        before = self.module.prior_hooks_state(self.prior)
        def unreadable(path, mode, *args, **kwargs):
            if path == self.prior and mode == os.R_OK:
                return False
            return real_access(path, mode, *args, **kwargs)
        with patch.object(self.module.os, 'access', unreadable):
            self.assertNotEqual(before, self.module.prior_hooks_state(self.prior))


if __name__ == '__main__':
    unittest.main()
