"""A5B synchronous integrity contract, no installed/live home access."""
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / 'lib'


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


class BenchSummaryTests(unittest.TestCase):
    def test_n5_nearest_rank_p95(self):
        spec = importlib.util.spec_from_file_location('bench', Path(__file__).parent / 'helpers/bench-attach-fastpath.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.summarize([5, 1, 4, 2, 3]), {'n': 5, 'p50_ms': 3, 'p95_ms': 5})


if __name__ == '__main__':
    unittest.main()
