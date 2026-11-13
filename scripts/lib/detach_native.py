"""The native detach program (Trellis 1.5.1 phase A, extended in 1.5.2).

Run by attachment.sh as `python3 -I -B -c <text>`, where the text is a line
`ATTACHMENT_FS = r'<payload>/scripts/lib/attachment_fs.py'` followed by this
file, so the crash suites can substitute the `checkpoint` seam in a copy.
The shared filesystem primitives load from that absolute payload path, never
from sys.path.
"""
import base64
import hashlib
import importlib.util
import json
import os
import signal
import stat
import sys


def _load_attachment_fs(path):
    spec = importlib.util.spec_from_file_location("trellis_attachment_fs", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return {name: value for name, value in vars(module).items() if not name.startswith("__")}


globals().update(_load_attachment_fs(ATTACHMENT_FS))  # noqa: F821 (set by the caller's first line)


def checkpoint(label):
    # Called after every durable step. The crash suites substitute this one
    # line in a copy of the program; nothing in the product activates it.
    return None  # crash-test seam


def visible(value):
    # _attachment_visible under LC_ALL=C: only C0 controls and DEL escape.
    out = []
    for byte in bytearray(os.fsencode(value)):
        if byte == 10:
            out.append(b"\\n")
        elif byte == 13:
            out.append(b"\\r")
        elif byte == 9:
            out.append(b"\\t")
        elif byte < 32 or byte == 127:
            out.append(("\\x%02x" % byte).encode("ascii"))
        else:
            out.append(bytes(bytearray([byte])))
    return b"".join(out)


# A render the shell must begin (exit status of a `renders` run).
BEGIN = 77


class Refused(Stop):
    def __init__(self, action, code, path, status=3):
        Stop.__init__(self, status)
        if action:
            message = (b"trellis " + os.fsencode(action) + b": refused (" + code.encode("ascii")
                       + b"): " + visible(path) + b"\n")
            sys.stderr.flush()
            os.write(2, message)


def pinned_exact(path, artifact):
    # _attachment_path_exact_pinned: the canonical parent, then the leaf by
    # name from inside it. Changes the working directory.
    parent, base = os.path.split(path)
    return canonical_dir(parent) and path_exact("./" + base, artifact)


def canonical_dir_kept(value):
    # canonical_dir without moving the working directory (the shell checks
    # run in subshells).
    here = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    try:
        return canonical_dir(value)
    finally:
        os.fchdir(here)
        os.close(here)


def file_state(path):
    info = lstat_or_none(path)
    if info is None:
        return None
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_mode)


def verify_owner(action):
    # _attachment_verify_detach_owner_artifacts: every non-render artifact,
    # sorted by path, must be exact; the withdrawn runtime anchor of a refused
    # attach may be absent.
    record = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    root = record["worktree_root"]
    renders = set(render["path"] for render in (record.get("renders") or []))
    artifacts = [artifact for artifact in record["artifacts"] if artifact["path"] not in renders]
    for artifact in sorted(artifacts, key=lambda item: item["path"]):
        relative = artifact["path"]
        destination = root + "/" + relative
        if relative == ".trellis/runtime" and parent_safe(root, relative) and not exists(destination):
            continue
        if not parent_safe(root, relative) or not pinned_exact(destination, artifact):
            code = "owned-symlink-drift" if artifact.get("kind") == "symlink" else "owned-file-drift"
            raise Refused(action, code, destination)


def artifacts_exact(record):
    root = record["worktree_root"]
    renders = set(render["path"] for render in (record.get("renders") or []))
    artifacts = [artifact for artifact in record["artifacts"] if artifact["path"] not in renders]
    for artifact in sorted(artifacts, key=lambda item: item["path"]):
        relative = artifact["path"]
        destination = root + "/" + relative
        if relative == ".trellis/runtime" and parent_safe(root, relative) and not exists(destination):
            continue
        if not parent_safe(root, relative) or not pinned_exact(destination, artifact):
            return False
    return True


def verify_owners():
    # Every check attachment_verify_detach makes of one owner, for all of a
    # checkout's owners in one pass: a regular mode-0600 file, the schema
    # (judged by jq, passed in as .valid), its canonical location (.canonical),
    # canonical roots, ids that hash the root and its git common dir, and
    # exact artifacts. Any failure exits 10 without naming it: the caller
    # repeats the per-owner checks, which name the first refusal exactly.
    entries = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    if not isinstance(entries, list):
        refuse(10)
    records = []
    for entry in entries:
        path = entry["path"]
        info = lstat_or_none(path)
        if info is None or not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
            refuse(10)
        if entry["valid"] is not True or entry["canonical"] is not True:
            refuse(10)
        record = entry["record"]
        if not canonical_dir_kept(record["project_root"]) or not canonical_dir_kept(record["worktree_root"]):
            refuse(10)
        if sha256_text(record["worktree_root"]) != record["worktree_id"]:
            refuse(10)
        records.append(record)
    commons = git_common_dirs(sorted(set(record["worktree_root"] for record in records)))
    for record in records:
        common = commons.get(record["worktree_root"])
        if common is None or sha256_text(common) != record["checkout_id"]:
            refuse(10)
        if not artifacts_exact(record):
            refuse(10)


class DetachCommit(object):
    def __init__(self, action, journal_path, owner_pid):
        self.action = action
        self.journal_path = journal_path
        self.owner_pid = owner_pid
        with open(journal_path, "rb") as handle:
            self.journal = json.loads(handle.read().decode("utf-8"))
        self.state = file_state(journal_path)
        self.root = self.journal["original_owner"]["worktree_root"]
        self.remove = self.journal["remove"]

    @property
    def removal(self):
        return self.journal["removal"]

    def guard(self):
        if os.getppid() != self.owner_pid:
            orphaned()

    def write_journal(self, *labels):
        # _attachment_write_json: never through a symlink, from a canonical
        # parent, a private temporary renamed over the journal. The journal
        # must still be the bytes this process last wrote or read.
        if is_link(self.journal_path) or file_state(self.journal_path) != self.state:
            raise Refused(self.action, "journal-invalid", self.journal_path)
        directory = os.path.dirname(self.journal_path)
        if not canonical_dir_kept(directory):
            refuse(1)
        data = (json.dumps(self.journal, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
        temporary = "%s.tmp.%s" % (self.journal_path, hashlib.sha256(os.urandom(16)).hexdigest()[:6])
        self.guard()
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.fchmod(fd, 0o600)
            view = memoryview(data)
            while view:
                self.guard()
                view = view[os.write(fd, view):]
        except BaseException:
            os.close(fd)
            os.unlink(temporary)
            raise
        os.close(fd)
        self.guard()
        os.rename(temporary, self.journal_path)
        self.state = file_state(self.journal_path)
        for label in labels:
            checkpoint(label)

    def set_intent(self, path):
        if self.removal is not None:
            refuse(1)
        nonce = hashlib.sha256(os.urandom(32)).hexdigest()
        self.journal["removal"] = {"path": path, "nonce": nonce}
        self.write_journal("intent")

    def clear_intent(self):
        # Owner ruling 2026-11-11 (1.5.1, option A): the clear that ends the
        # removal of remove[phase] and the phase advance are one durable
        # write. Separately, a kill between them at phase 0 left a journal
        # whose preflight refused the already removed first leaf forever. The
        # combined state is one the shell protocol also reaches (between an
        # artifact's phase write and the next intent), so 1.5.0 recovers it.
        self.journal["removal"] = None
        self.journal["phase"] += 1
        self.cleared = True
        self.write_journal("clear", "phase")

    def claim_state(self, path):
        # _attachment_journal_claim_layout + _attachment_claim_layout:
        # (state, quarantine) or None when the layout is not ours.
        removal = self.removal
        if removal is None or removal["path"] != path:
            return None
        quarantine = claim_layout(path, removal["nonce"])
        if not exists(quarantine):
            return ("absent", quarantine)
        if not canonical_dir_kept(quarantine):
            return None
        try:
            entries = os.listdir(quarantine)
        except OSError:
            return None
        if not entries:
            return ("empty", quarantine)
        if entries != ["artifact"]:
            return None
        return ("claimed", quarantine)

    def absent_or_exact(self, artifact):
        # _attachment_artifact_absent_or_exact
        relative = artifact["path"]
        if not parent_safe(self.root, relative):
            return False
        destination = self.root + "/" + relative
        if not claim_namespace_valid(destination, self.removal):
            return False
        if self.removal is not None and self.removal["path"] == destination:
            layout = self.claim_state(destination)
            if layout is None:
                return False
            state, quarantine = layout
            if exists(destination):
                return state != "claimed" and pinned_exact(destination, artifact)
            if state in ("absent", "empty"):
                return True
            return pinned_exact(quarantine + "/artifact", artifact)
        if exists(destination):
            return pinned_exact(destination, artifact)
        return True

    def preflight(self):
        # _attachment_detach_preflight_remaining: at phase 0 every planned
        # removal is exact before anything is touched.
        removal_path = self.removal["path"] if self.removal is not None else ""
        for artifact in sorted(self.remove, key=lambda item: item["path"]):
            relative = artifact["path"]
            destination = self.root + "/" + relative
            if removal_path and destination == removal_path:
                if self.absent_or_exact(artifact):
                    continue
            elif parent_safe(self.root, relative) and pinned_exact(destination, artifact):
                continue
            elif (relative == ".trellis/runtime" and parent_safe(self.root, relative)
                  and not exists(destination)):
                continue
            raise Refused(self.action, "artifact-changed", destination)

    def remove_pinned(self, path, artifact):
        # _attachment_remove_pinned with no identity requirement and an exact
        # claim. Returns the shell function's status.
        parent, base = os.path.split(path)
        if not canonical_dir(parent):
            return 3
        if not claim_namespace_valid(path, self.removal):
            return 3
        resuming = True
        if self.removal is None:
            self.set_intent(path)
            resuming = False
        elif self.removal["path"] != path:
            return 3 if exists(path) else 0
        layout = self.claim_state(path)
        if layout is None:
            return 3
        if not resuming and layout[0] != "absent":
            return 3
        if not claim_namespace_valid(path, self.removal):
            return 3
        try:
            os.chdir(parent)
            pinned_parent = os.getcwd()
        except OSError:
            return 1
        if pinned_parent != parent:
            return 3
        layout = self.claim_state(path)
        if layout is None:
            return 3
        state, quarantine = layout
        leaf = "./" + base
        name = "./" + os.path.basename(quarantine)
        claimed = name + "/artifact"
        kind = artifact["kind"]
        if state == "absent":
            if not exists(leaf):
                self.clear_intent()
                return 0
            try:
                self.guard()
                os.mkdir(name, 0o700)
            except OSError:
                return 3
            checkpoint("q_mkdir")
            if not self.claim_leaf(leaf, name):
                return 3
        elif state == "empty":
            if exists(leaf):
                if not self.claim_leaf(leaf, name):
                    return 3
            else:
                try:
                    self.guard()
                    os.rmdir(name)
                except OSError:
                    return 1
                checkpoint("q_rmdir")
                self.clear_intent()
                return 0
        elif exists(leaf):
            return 3
        if not path_exact(claimed, artifact):
            if not exists(leaf):
                try:
                    self.guard()
                    os.rename(claimed, leaf)
                    os.rmdir(name)
                except OSError:
                    return 3
            return 3
        status = 0
        try:
            self.guard()
            if kind in ("directory", "parent"):
                os.rmdir(claimed)
            elif kind in ("file", "symlink"):
                os.unlink(claimed)
            else:
                status = 2
        except OSError:
            status = 3 if kind in ("directory", "parent") else 1
        if status:
            if exists(claimed) and not exists(leaf):
                try:
                    self.guard()
                    os.rename(claimed, leaf)
                except OSError:
                    return status
            try:
                os.rmdir(name)
            except OSError:
                pass
            return status
        checkpoint("q_rm")
        try:
            self.guard()
            os.rmdir(name)
        except OSError:
            return 1
        checkpoint("q_rmdir")
        self.clear_intent()
        return 0

    def claim_leaf(self, leaf, name):
        # The claim goes through the pinned quarantine, never its name: a
        # symlink swapped in for it fails O_NOFOLLOW or the identity check.
        try:
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError:
            return False
        try:
            pinned = fd_identity(fd)
            if identity(name) != pinned:
                return False
            self.guard()
            os.fchmod(fd, 0o700)
            try:
                self.guard()
                os.rename(leaf, "artifact", dst_dir_fd=fd)
            except OSError:
                return False
            checkpoint("q_claim")
            return identity(name) == pinned
        finally:
            os.close(fd)

    def remove_one(self, artifact):
        # _attachment_detach_remove_one
        relative = artifact.get("path")
        kind = artifact.get("kind")
        if not isinstance(relative, str) or not isinstance(kind, str):
            refuse(2)
        destination = self.root + "/" + relative
        if not parent_safe(self.root, relative):
            raise Refused(self.action, "artifact-changed", destination)
        if kind in ("parent", "directory"):
            if not exists(destination):
                return
            if is_dir(destination):
                try:
                    self.guard()
                    os.rmdir(destination)
                    return
                except OSError:
                    if is_dir(destination):
                        return
            raise Refused(self.action, "parent-not-removable", destination)
        if kind not in ("file", "symlink"):
            refuse(2)
        status = self.remove_pinned(destination, artifact)
        if status == 3:
            raise Refused(self.action, "artifact-changed", destination)
        if status:
            refuse(status)

    # --- render restore (finish phase 1): the steps of
    # attach_detach_render_resume for the pending render, in this process.
    # Each step makes the checks its shell twin makes, writes the same
    # journal states in the same order, and reports the same kill points.

    def clear_removal(self):
        # _attachment_clear_removal_intent: render claims clear without a
        # phase (the phase belongs to the commit loop).
        self.journal["removal"] = None
        self.write_journal("clear")

    def external(self):
        return self.journal["external"]

    def pending(self):
        return self.external()["render_pending"]

    def render_path(self, pending):
        return self.root + "/" + pending["render"]["path"]

    @staticmethod
    def render_artifact(pending, sha, mode):
        return {"path": pending["render"]["path"], "kind": "file", "sha256": sha, "mode": mode}

    def journal_claim(self, path):
        # _attachment_journal_claim_layout: (state, quarantine) or None.
        return self.claim_state(path)

    def step_refuse(self, status, code):
        # _attachment_detach_step_refuse
        if status != 3:
            raise Stop(status)
        if code == "render-conflict":
            external = self.external()
            render = (external.get("render_pending") or {}).get("render")
            if render is None:
                render = external["renders"][external["render_phase"]]
            path = self.root + "/" + render["path"]
            raise Refused(self.action, "render-conflict",
                          "%s; it or its directory no longer matches detach journal %s; restore the bytes Trellis rendered (journal external.renders[].after_base64), then rerun trellis recover"
                          % (path, self.journal_path))
        raise Refused(self.action, code,
                      "%s; its recorded owner commit or phase does not allow this step; keep the journal and run trellis doctor"
                      % self.journal_path)

    def file_matches(self, path, identity_value, sha, mode):
        return (is_file(path) and identity_matches(path, identity_value, "file")
                and sha256_file(path) == sha and mode_matches(path, mode))

    def stage_path_valid(self, pending, stage):
        relative = pending["render"]["path"]
        if not parent_safe(self.root, relative) or not isinstance(stage, str) or not valid_absolute(stage):
            return False
        destination = self.root + "/" + relative
        prefix = "%s/.%s.attachment-stage-%s." % (os.path.dirname(destination), os.path.basename(destination),
                                                 self.journal["attachment_id"])
        suffix = stage[len(prefix):] if stage.startswith(prefix) else ""
        return bool(suffix) and "/" not in suffix and not has_controls(suffix)

    def step_valid(self):
        # What _attachment_detach_journal_valid re-checks of the live tree
        # before every step: canonical roots, the worktree id, and the pending
        # render's runtime state (_attachment_detach_render_pending_runtime_valid).
        # The journal itself is the one this process wrote, checked unchanged
        # on disk before every write; the shell validated it before we began.
        original = self.journal["original_owner"]
        if file_state(self.journal_path) != self.state:
            raise Refused(self.action, "journal-invalid", self.journal_path)
        if (not canonical_dir_kept(original["project_root"]) or not canonical_dir_kept(original["worktree_root"])
                or sha256_text(original["worktree_root"]) != original["worktree_id"]):
            refuse(2)
        status = self.pending_runtime_status()
        if status:
            refuse(status)

    def pending_runtime_status(self):
        pending = self.pending()
        if pending is None or "parent_identity" not in pending:
            return 0
        path = self.render_path(pending)
        if identity(os.path.dirname(path)) != pending["parent_identity"]:
            return 3
        if not parent_safe(self.root, pending["render"]["path"]) or not claim_namespace_valid(path, self.removal):
            return 3
        result_exists = pending["result_exists"]
        stage = None
        stage_identity = pending.get("staging_identity") or ""
        if result_exists is True:
            if hashlib.sha256(base64.b64decode(pending["result_base64"])).hexdigest() != pending["result_sha256"]:
                return 2
            stage = pending["staging_path"]
            if not self.stage_path_valid(pending, stage):
                return 2
            if exists(stage):
                if stage_identity:
                    if not self.file_matches(stage, stage_identity, pending["result_sha256"], pending["result_mode"]):
                        return 3
                elif not is_file(stage):
                    return 3
            elif stage_identity:
                if not self.file_matches(path, stage_identity, pending["result_sha256"], pending["result_mode"]):
                    return 3
        source = self.render_artifact(pending, pending["source_sha256"], pending["source_mode"])
        removal = self.removal
        if removal is not None:
            if removal["path"] == path:
                layout = self.journal_claim(path)
                if layout is None:
                    return 3
                if layout[0] == "claimed":
                    claimed = layout[1] + "/artifact"
                    if not identity_matches(claimed, pending["source_identity"], "file") or not path_exact(claimed, source):
                        return 3
                    if not exists(path):
                        return 0
            elif result_exists is True and removal["path"] == stage:
                layout = self.journal_claim(stage)
                if layout is None:
                    return 3
                if layout[0] == "claimed":
                    claimed = layout[1] + "/artifact"
                    result = self.render_artifact(pending, pending["result_sha256"], pending["result_mode"])
                    if not identity_matches(claimed, stage_identity, "file") or not path_exact(claimed, result):
                        return 3
        if self.file_matches(path, pending["source_identity"], pending["source_sha256"], pending["source_mode"]):
            return 0
        if result_exists is False:
            return 0 if not exists(path) else 3
        if not self.file_matches(path, stage_identity, pending["result_sha256"], pending["result_mode"]):
            return 3
        return 0

    def result_matches(self, path, pending):
        # attach_detach_render_pending_result_matches
        if pending["result_exists"] is False:
            return not exists(path)
        return self.file_matches(path, pending.get("staging_identity") or "", pending["result_sha256"], pending["result_mode"])

    def pending_state(self, pending):
        # attach_detach_render_pending_state
        path = self.render_path(pending)
        source = self.render_artifact(pending, pending["source_sha256"], pending["source_mode"])
        if not claim_namespace_valid(path, self.removal):
            return None
        removal = self.removal
        if removal is not None and removal["path"] == path:
            layout = self.journal_claim(path)
            if layout is None:
                return None
            if layout[0] == "claimed":
                claimed = layout[1] + "/artifact"
                if not identity_matches(claimed, pending["source_identity"], "file") or not path_exact(claimed, source):
                    return None
                if not exists(path):
                    return "claimed"
        if self.file_matches(path, pending["source_identity"], pending["source_sha256"], pending["source_mode"]):
            return "source"
        if self.result_matches(path, pending):
            return "published"
        return None

    def published_matches(self, destination):
        if not self.result_matches(destination, self.pending()):
            self.step_refuse(3, "render-conflict")

    def step(self, status, label):
        # A public step's status; its kill point fires only on success.
        if status:
            raise Stop(status)
        checkpoint(label)

    def resume_render(self):
        # attach_detach_render_resume
        pending = self.pending()
        if pending is None:
            self.step_refuse(3, "journal-phase-conflict")
        destination = self.render_path(pending)
        state = self.pending_state(pending)
        if state is None:
            self.step_refuse(3, "render-conflict")
        fault = os.environ.get("ATTACHMENT_FAULT_PHASE", "")
        if state == "source":
            self.step(self.render_stage(), "attachment_detach_render_stage")
            self.step(self.render_claim(), "attachment_detach_render_claim")
            if fault == "detach-render-claimed":
                raise Stop(5)
        elif state == "published":
            self.published_matches(destination)
            self.step(self.render_cleanup(), "attachment_detach_render_cleanup")
            self.published_matches(destination)
            self.step(self.render_finish(), "attachment_detach_render_finish")
            return
        self.step(self.render_stage(), "attachment_detach_render_stage")
        self.step(self.render_publish(), "attachment_detach_render_publish")
        if fault == "detach-render-published":
            raise Stop(5)
        self.published_matches(destination)
        self.step(self.render_cleanup(), "attachment_detach_render_cleanup")
        self.published_matches(destination)
        self.step(self.render_finish(), "attachment_detach_render_finish")

    def render_stage(self):
        # _attachment_detach_render_stage_impl
        self.step_valid()
        pending = self.pending()
        if pending is None:
            return 2
        if pending["result_exists"] is not True:
            return 0
        stage = pending["staging_path"]
        recorded = pending.get("staging_identity") or ""
        expected = pending["result_sha256"]
        mode = pending["result_mode"]
        if not self.stage_path_valid(pending, stage):
            return 3
        parent, base = os.path.split(stage)
        expected_parent = pending.get("parent_identity")
        if identity(parent) != expected_parent or not claim_namespace_valid(stage, self.removal):
            return 3
        if not recorded and exists(stage):
            status = self.reclaim_unidentified_stage(stage, expected_parent)
            if status:
                return status
        if exists(stage):
            if not recorded or not identity_matches(stage, recorded, "file"):
                return 3
            if sha256_file(stage) != expected or not mode_matches(stage, mode):
                return 3
            return 0
        if recorded:
            return 3
        if not canonical_dir(parent):
            return 3
        try:
            self.guard()
            fd = os.open("./" + base, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except OSError:
            return 3
        try:
            staged = fd_identity(fd)
            if identity("./" + base) != staged:
                return 3
            # The stage is complete before its identity is journaled: a crash
            # before that write leaves an unidentified stage, which every
            # release reclaims and stages again. (Journaling the identity
            # first, as up to 1.5.1, let a crash leave a recorded stage whose
            # bytes never match, refused forever.)
            self.guard()
            os.fchmod(fd, int(mode, 8))
            view = memoryview(base64.b64decode(pending["result_base64"]))
            while view:
                self.guard()
                view = view[os.write(fd, view):]
        finally:
            os.close(fd)
        if not identity_matches("./" + base, staged, "file"):
            return 3
        if sha256_file("./" + base) != expected or not mode_matches("./" + base, mode):
            return 3
        pending = self.pending()
        if not (pending is not None and pending["result_exists"] is True
                and pending.get("staging_identity") is None and isinstance(pending.get("staging_path"), str)):
            return 2
        pending["staging_identity"] = staged
        self.write_journal("render_stage_identity")
        return 0

    def reclaim_unidentified_stage(self, stage, expected_parent):
        # _attachment_reclaim_unidentified_stage for a file stage.
        parent, base = os.path.split(stage)
        here = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            if not canonical_dir(parent) or identity(".") != expected_parent:
                return 3
            if exists("./" + base):
                if not (is_link("./" + base) or is_file("./" + base)):
                    return 3
                try:
                    self.guard()
                    os.unlink("./" + base)
                except OSError:
                    return 1
            return 0
        finally:
            os.fchdir(here)
            os.close(here)

    def claim_pinned(self, path, artifact, expected_identity):
        # _attachment_claim_pinned
        parent, base = os.path.split(path)
        if artifact["kind"] != "file":
            return 2
        if not canonical_dir(parent) or not claim_namespace_valid(path, self.removal):
            return 3
        if self.removal is None:
            if not identity_matches(path, expected_identity, "file") or not path_exact(path, artifact):
                return 3
            self.set_intent(path)
        elif self.removal["path"] != path:
            return 3
        if self.journal_claim(path) is None or not claim_namespace_valid(path, self.removal):
            return 3
        try:
            os.chdir(parent)
            pinned_parent = os.getcwd()
        except OSError:
            return 1
        if pinned_parent != parent:
            return 3
        layout = self.journal_claim(path)
        if layout is None:
            return 3
        state, quarantine = layout
        leaf = "./" + base
        name = "./" + os.path.basename(quarantine)
        claimed = name + "/artifact"
        if state == "absent":
            if not identity_matches(leaf, expected_identity, "file") or not path_exact(leaf, artifact):
                return 3
            try:
                self.guard()
                os.mkdir(name, 0o700)
            except OSError:
                return 3
            checkpoint("q_mkdir")
            if not self.claim_leaf(leaf, name):
                return 3
        elif state == "empty":
            # Killed between creating the journaled quarantine and claiming
            # the leaf: finish that claim (the shell twin does the same).
            if not identity_matches(leaf, expected_identity, "file") or not path_exact(leaf, artifact):
                return 3
            if not self.claim_leaf(leaf, name):
                return 3
        elif state == "claimed":
            if exists(leaf):
                return 3
        else:
            return 3
        if not identity_matches(claimed, expected_identity, "file") or not path_exact(claimed, artifact):
            self.restore_pinned_claim(path)
            return 3
        return 0

    def restore_pinned_claim(self, path):
        # _attachment_restore_pinned_claim
        parent, base = os.path.split(path)
        if not canonical_dir(parent):
            return 3
        layout = self.journal_claim(path)
        if layout is None or layout[0] != "claimed":
            return 3
        name = "./" + os.path.basename(layout[1])
        claimed = name + "/artifact"
        if not is_file(claimed) or exists("./" + base):
            return 3
        staged = identity(claimed)
        try:
            self.guard()
            os.link(claimed, "./" + base, follow_symlinks=False)
        except OSError:
            return 3
        if not identity_matches("./" + base, staged, "file"):
            return 3
        self.guard()
        os.unlink(claimed)
        checkpoint("q_rm")
        os.rmdir(name)
        checkpoint("q_rmdir")
        self.clear_removal()
        return 0

    def discard_pinned_claim(self, path, artifact, expected_identity):
        # _attachment_discard_pinned_claim
        parent = os.path.dirname(path)
        if not canonical_dir(parent):
            return 3
        layout = self.journal_claim(path)
        if layout is None:
            return 3
        try:
            os.chdir(parent)
            pinned_parent = os.getcwd()
        except OSError:
            return 1
        if pinned_parent != parent:
            return 3
        name = "./" + os.path.basename(layout[1])
        claimed = name + "/artifact"
        if layout[0] == "claimed":
            if not identity_matches(claimed, expected_identity, "file") or not path_exact(claimed, artifact):
                return 3
            try:
                self.guard()
                os.unlink(claimed)
            except OSError:
                return 1
            checkpoint("q_rm")
        elif layout[0] == "absent":
            # Killed after the claim and its quarantine were removed, before
            # the clear: only the clear is left, unless the claimed file is
            # back in place (the shell twin does the same).
            leaf = "./" + os.path.basename(path)
            if exists(leaf) and identity_matches(leaf, expected_identity, "file"):
                return 3
            self.clear_removal()
            return 0
        elif layout[0] != "empty":
            return 3
        try:
            self.guard()
            os.rmdir(name)
        except OSError:
            return 1
        checkpoint("q_rmdir")
        self.clear_removal()
        return 0

    def render_claim(self):
        # _attachment_detach_render_claim_impl
        self.step_valid()
        pending = self.pending()
        if pending is None:
            return 2
        source = self.render_artifact(pending, pending["source_sha256"], pending["source_mode"])
        return self.claim_pinned(self.render_path(pending), source, pending["source_identity"])

    def render_publish(self):
        # _attachment_detach_render_publish_impl
        self.step_valid()
        pending = self.pending()
        if pending is None:
            return 2
        path = self.render_path(pending)
        source = self.render_artifact(pending, pending["source_sha256"], pending["source_mode"])
        layout = self.journal_claim(path)
        if layout is None or layout[0] != "claimed":
            return 3
        claimed = layout[1] + "/artifact"
        if not identity_matches(claimed, pending["source_identity"], "file") or not path_exact(claimed, source):
            return 3
        if exists(path):
            return 3
        if pending["result_exists"] is False:
            return 0
        return self.publish_pinned_stage(pending["staging_path"], path, pending.get("staging_identity") or "",
                                         pending["result_sha256"], pending["result_mode"])

    def publish_pinned_stage(self, stage, destination, staged, expected, mode):
        # _attachment_publish_pinned_stage
        parent = os.path.dirname(destination)
        if os.path.dirname(stage) != parent or not canonical_dir(parent):
            return 3
        stage_name = "./" + os.path.basename(stage)
        destination_name = "./" + os.path.basename(destination)
        if not identity_matches(stage_name, staged, "file"):
            return 3
        if sha256_file(stage_name) != expected or not mode_matches(stage_name, mode):
            return 3
        if exists(destination_name):
            return 3
        try:
            self.guard()
            os.link(stage_name, destination_name, follow_symlinks=False)
        except OSError:
            return 3
        if not identity_matches(destination_name, staged, "file"):
            return 3
        if sha256_file(destination_name) != expected or not mode_matches(destination_name, mode):
            return 3
        return 0

    def render_cleanup(self):
        # _attachment_detach_render_cleanup_impl
        self.step_valid()
        pending = self.pending()
        if pending is None:
            return 2
        path = self.render_path(pending)
        source = self.render_artifact(pending, pending["source_sha256"], pending["source_mode"])
        result_exists = pending["result_exists"]
        removal = self.removal
        if removal is not None:
            if removal["path"] == path:
                status = self.discard_pinned_claim(path, source, pending["source_identity"])
                if status:
                    return status
            elif result_exists is not True or removal["path"] != pending["staging_path"]:
                return 3
        if result_exists is not True:
            return 0 if self.removal is None else 3
        stage = pending["staging_path"]
        staged = pending.get("staging_identity") or ""
        result = self.render_artifact(pending, pending["result_sha256"], pending["result_mode"])
        removal = self.removal
        if removal is not None and removal["path"] == stage:
            layout = self.journal_claim(stage)
            if layout is None:
                return 3
            if layout[0] == "claimed":
                status = self.discard_pinned_claim(stage, result, staged)
            else:
                # A stage still in place is claimed first (the shell twin did
                # not, and left it behind); one already gone was claimed and
                # discarded, and the discard clears.
                status = ((self.claim_pinned(stage, result, staged) if exists(stage) else 0)
                          or self.discard_pinned_claim(stage, result, staged))
            if status:
                return status
        elif exists(stage):
            status = self.claim_pinned(stage, result, staged) or self.discard_pinned_claim(stage, result, staged)
            if status:
                return status
        return 0 if self.removal is None else 3

    def render_finish(self):
        # _attachment_detach_render_finish_impl
        self.step_valid()
        pending = self.pending()
        path = self.render_path(pending)
        if pending["result_exists"] is False:
            if exists(path):
                return 3
        elif not self.file_matches(path, pending.get("staging_identity") or "", pending["result_sha256"], pending["result_mode"]):
            return 3
        external = self.external()
        if not (self.journal["owner_committed"] is True and self.removal is None and external["phase"] == 1
                and external["render_pending"] is not None
                and external["render_phase"] < len(external["renders"])
                and external["render_pending"]["render"] == external["renders"][external["render_phase"]]):
            return 2
        external["render_phase"] += 1
        external["render_pending"] = None
        self.write_journal()
        return 0

    def mark_external(self, phase):
        # _attachment_detach_mark_external_phase_impl
        self.step_valid()
        external = self.external()
        if self.journal["owner_committed"] is not True or phase != external["phase"] + 1:
            refuse(3)
        if phase == 2 and not (external["render_phase"] == len(external["renders"])
                               and external["render_pending"] is None and self.removal is None):
            refuse(3)
        external["phase"] = phase
        self.write_journal("attachment_detach_mark_external_phase")

    def run_renders(self):
        # Finish phases 1 and 2: mark 1, every render restored, mark 2. A
        # render not yet begun stops the run with BEGIN: its begin computes
        # the restored bytes in the shell, which then runs this again.
        external = self.external()
        if external["phase"] == 0:
            self.mark_external(1)
        if external["phase"] != 1:
            return
        while True:
            if external["render_pending"] is not None:
                self.resume_render()
            elif external["render_phase"] < len(external["renders"]):
                raise Stop(BEGIN)
            else:
                break
        if self.removal is None:
            self.mark_external(2)

    # --- owner commit (spec 075 T4b): the rest of _attachment_detach_commit_locked.

    def owner_path(self, home):
        original = self.journal["original_owner"]
        return "%s/state/attachments/%s/%s.json" % (home, original["checkout_id"], original["worktree_id"])

    def file_matches_data(self, path, expected, filters):
        # _attachment_detach_file_matches_data: a valid owner record file whose
        # value is exactly `expected` (jq -cS comparison).
        record = owner_record_valid(path, filters)
        return record is not None and record == expected

    def commit_all(self, home, filters):
        journal = self.journal
        original = journal["original_owner"]
        next_owner = journal["next_owner"]
        owner = self.owner_path(home)
        total = len(self.remove)
        phase = journal["phase"]
        if journal["owner_committed"] is True:
            if (next_owner is None and exists(owner)) or (
                    next_owner is not None and not self.file_matches_data(owner, next_owner, filters)):
                raise Refused(self.action, "owner-changed", owner)
            return
        if not self.file_matches_data(owner, original, filters):
            if phase == total and ((next_owner is None and not exists(owner)) or (
                    next_owner is not None and self.file_matches_data(owner, next_owner, filters))):
                journal["owner_committed"] = True
                self.write_journal("owner_committed")
                return
            raise Refused(self.action, "owner-changed", owner)
        if phase < total:
            self.run()
        if not self.file_matches_data(owner, original, filters):
            raise Refused(self.action, "owner-changed", owner)
        if next_owner is None:
            # Exhausted registry contention leaves the owner and journal for
            # retry, as before: the registry writer stays the shell's own.
            status = shell_leaf(self.action, "local_registry_clear_attachment", home, original["fleet"],
                                original["project_id"], original["checkout_id"], original["worktree_id"],
                                original["attachment_id"])
            if status:
                raise Stop(status)
            if not self.file_matches_data(owner, original, filters):
                raise Refused(self.action, "owner-changed", owner)
            self.guard()
            os.unlink(owner)
            checkpoint("owner_rm")
        else:
            self.guard()
            status = write_private_json(owner, compact(next_owner))
            if status:
                refuse(status)
        journal["owner_committed"] = True
        self.write_journal("owner_committed")

    # --- finish (spec 075 T4b, step 2): _attach_detach_finish_journal_locked.
    # Leaves stay the shell's own: partial preflight, shared-restore rebase,
    # exclude transfer and restore, render begin, hooks restore, registry.

    def reload(self):
        # After a leaf that may have written the journal.
        with open(self.journal_path, "rb") as handle:
            self.journal = json.loads(handle.read().decode("utf-8"))
        self.state = file_state(self.journal_path)
        self.remove = self.journal["remove"]

    def leaf(self, function, *args):
        status = shell_leaf(self.action, function, *args)
        if exists(self.journal_path):
            self.reload()
        return status

    def finish(self, home, filters):
        journal_path = self.journal_path
        status = self.leaf("attach_detach_partial_journal_preflight", home, journal_path)
        if status:
            raise Stop(status)
        original = self.journal["original_owner"]
        original_json = compact(original)
        status = self.leaf("attach_detach_rebase_shared_restore", home, journal_path)
        if status:
            raise Stop(status)
        external = self.external()
        phase = external["phase"]
        action = external.get("exclude_action") or "none"
        if action == "transfer":
            status = self.leaf("attach_detach_transfer_exclude", compact(external))
            if status:
                raise Stop(status)
        if phase < 2:
            while True:
                status = journal_valid(journal_path, filters)
                if status:
                    raise Stop(status)
                try:
                    self.run_renders()
                    break
                except Stop as stop:
                    if stop.status != BEGIN:
                        raise
                status = self.leaf("attach_detach_render_begin", original_json, journal_path)
                if status:
                    raise Stop(status)
                # The shell harness's begin point, at the same durable write.
                checkpoint("attachment_detach_render_begin")
            external = self.external()
            if not (external["render_phase"] == len(external["renders"]) and external["render_pending"] is None):
                pending = "null" if external["render_pending"] is None else "present"
                raise Stop(self.leaf("attach_detach_finish_refusal", "renders", journal_path, str(phase),
                                     str(external["render_phase"]), str(len(external["renders"])), pending) or 3)
            if self.removal is not None:
                raise Stop(self.leaf("attach_detach_finish_refusal", "removal", journal_path, str(phase)) or 3)
            if external["phase"] < 2:
                self.mark_external(2)
            phase = 2
        external = self.external()
        if phase < 3:
            action = external.get("exclude_action") or "none"
            if action == "restore":
                status = self.leaf("attach_exclude_recover", compact(original["exclude"]))
                if status:
                    raise Stop(status)
            elif action not in ("none", "transfer"):
                raise Stop(4)
            self.mark_external(3)
            phase = 3
        if phase < 4:
            if external.get("restore_hooks") is True:
                status = self.leaf("attach_detach_restore_hooks", original_json)
                if status:
                    raise Stop(status)
            self.mark_external(4)
            phase = 4
        if phase < 5:
            fault = os.environ.get("ATTACHMENT_FAULT_PHASE", "")
            if external.get("clear_registry") is True:
                if self.leaf("attach_detach_registry_already_clear", home, original_json):
                    status = self.leaf("attach_detach_restore_registry", home, original_json)
                    if status:
                        raise Stop(status)
            elif external.get("registry_update") is not None:
                if fault == "detach-registry-before":
                    raise Stop(5)
                status = self.leaf("local_registry_update_harnesses", home, original["fleet"], original["project_id"],
                                   original["checkout_id"], compact(external["registry_update"]))
                if status:
                    raise Stop(status)
                if fault == "detach-registry-after":
                    raise Stop(5)
            self.mark_external(5)
        # _attachment_detach_finalize_impl
        status = journal_valid(journal_path, filters)
        if status:
            raise Stop(status)
        if self.journal["owner_committed"] is not True or self.external()["phase"] != 5:
            raise Stop(3)
        self.guard()
        os.unlink(journal_path)

    def run(self):
        phase = self.journal["phase"]
        total = len(self.remove)
        if self.journal["owner_committed"] is not False or not 0 <= phase <= total:
            refuse(2)
        if phase == 0:
            self.preflight()
        while phase < total:
            self.cleared = False
            self.remove_one(self.remove[phase])
            phase += 1
            if self.cleared:
                if self.journal["phase"] != phase:
                    refuse(2)
                continue
            # No clear of our own: a removal journaled for another path, or a
            # parent entry. Only the phase moves, as before.
            self.journal["phase"] = phase
            self.write_journal("phase")


def owner_record_valid(path, filters):
    # _attachment_owner_json_valid: a regular mode-0600 file whose JSON passes
    # the owner schema (judged by jq, as `jq -e`). The parsed record, or None.
    import subprocess
    info = lstat_or_none(path)
    if info is None or not stat.S_ISREG(info.st_mode):
        return None
    try:
        with open(path, "rb") as handle:
            record = json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError):
        return None
    if record is None or record is False or stat.S_IMODE(info.st_mode) & 0o777 != 0o600:
        return None
    result = subprocess.run(["jq", "-e", filters["owner"], path], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return record if result.returncode == 0 else None


def shell_leaf(action, function, *args):
    # One shell function of this payload, as a leaf: a bash (the caller's own,
    # TRELLIS_DETACH_BASH) that sources attach-project.sh beside this program
    # and calls it with ATTACHMENT_ACTION set. Its status is the function's.
    # Transfer records can exceed Linux's per-argument limit. Send the leaf's
    # arguments NUL-framed on stdin instead; the function itself sees EOF.
    import subprocess
    bash = os.environ.get("TRELLIS_DETACH_BASH", "")
    script = os.path.dirname(os.path.dirname(ATTACHMENT_FS)) + "/attach-project.sh"  # noqa: F821
    if not bash.startswith("/") or not is_file(script):
        return 1
    env = dict(os.environ)
    env.pop("TRELLIS_LIBS_PRELOADED", None)
    sys.stdout.flush()
    sys.stderr.flush()
    framed = b"".join(os.fsencode(arg) + b"\0" for arg in args)
    return subprocess.run([bash, "-c", '. "$1" || exit 1; shift; ATTACHMENT_ACTION=$1; shift; '
                           'while IFS= read -r -d "" arg; do set -- "$@" "$arg"; done; "$@" < /dev/null',
                           "trellis-detach-leaf", script, action, function], input=framed, env=env).returncode


# --- journal validation (spec 075 T4, R5): `_attachment_detach_journal_valid`
# with its jq filters as the single source of truth. The shell passes them in
# the environment (TRELLIS_DETACH_JOURNAL_SCHEMA, TRELLIS_DETACH_JOURNAL_INVARIANTS,
# TRELLIS_OWNER_SCHEMA); one jq process judges every filter the shell ran,
# each the way `jq -e` decides (last output neither false nor null, an error
# or no output fails). Statuses as the shell's: 0, 2 shape, 3 conflict.

def jq_verdicts(path, filters):
    import subprocess
    def judged(expression):
        return "(try ([%s] | (length > 0 and (last | . != false and . != null))) catch false)" % expression
    owner = "(%s)" % filters["owner"]
    program = "{%s}" % ", ".join([
        "parsed: (. != false and . != null)",
        "schema: " + judged(filters["schema"]),
        "original: " + judged(".original_owner | " + owner),
        "legacy_partial: (try (.next_owner != null and .external.registry_update == null) catch false)",
        "next: (if .next_owner == null then true else " + judged(".next_owner | " + owner) + " end)",
        "transfer: (if (try .external.transfer catch null) == null then true else ("
        + judged(".external.transfer.expected | " + owner) + " and "
        + judged(".external.transfer.after | " + owner) + ") end)",
        "invariants: " + judged(". as $journal_root | .original_owner as $original | .next_owner as $next | $journal_root | "
                                + filters["invariants"]),
    ])
    try:
        result = subprocess.run(["jq", "-c", program, path], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    if result.returncode != 0:
        return None
    try:
        verdicts = json.loads(result.stdout.decode("utf-8"))
    except ValueError:
        return None
    return verdicts if isinstance(verdicts, dict) else None


def journal_data_valid(path, filters):
    # _attachment_detach_journal_data_valid
    if not valid_absolute(path):
        return 2
    info = lstat_or_none(path)
    if info is None or not stat.S_ISREG(info.st_mode):
        return 2
    verdicts = jq_verdicts(path, filters)
    if verdicts is None or verdicts.get("parsed") is not True:
        return 2
    if stat.S_IMODE(info.st_mode) & 0o777 != 0o600:
        return 3
    if verdicts.get("schema") is not True or verdicts.get("original") is not True:
        return 2
    if verdicts.get("legacy_partial") is True:
        sys.stderr.write("trellis attachment: legacy partial detach journal lacks a trusted registry snapshot\n")
        return 2
    if not all(verdicts.get(name) is True for name in ("next", "transfer", "invariants")):
        return 2
    with open(path, "rb") as handle:
        journal = json.loads(handle.read().decode("utf-8"))
    journal_dir = os.path.dirname(path)
    home = os.path.dirname(os.path.dirname(journal_dir))
    if journal_dir != home + "/state/attachment-journals":
        return 2
    if path != "%s/state/attachment-journals/detach-%s.json" % (home, journal["attachment_id"]):
        return 2
    transfer = journal["external"].get("transfer")
    if transfer is not None:
        expected = transfer["expected"]
        if transfer["owner_path"] != "%s/state/attachments/%s/%s.json" % (
                home, expected["checkout_id"], expected["worktree_id"]):
            return 2
    return 0


def owner_roots_and_ids_valid(owner):
    # _attachment_validate_roots + _attachment_validate_ids
    root = owner["worktree_root"]
    if not canonical_dir_kept(owner["project_root"]) or not canonical_dir_kept(root):
        return False
    if sha256_text(root) != owner["worktree_id"]:
        return False
    common = git_common_dirs([root]).get(root)
    return common is not None and sha256_text(common) == owner["checkout_id"]


def journal_valid(path, filters):
    # _attachment_detach_journal_valid
    status = journal_data_valid(path, filters)
    if status:
        return status
    with open(path, "rb") as handle:
        journal = json.loads(handle.read().decode("utf-8"))
    if not owner_roots_and_ids_valid(journal["original_owner"]):
        return 2
    probe = DetachCommit.__new__(DetachCommit)
    probe.journal = journal
    probe.journal_path = path
    probe.root = journal["original_owner"]["worktree_root"]
    return probe.pending_runtime_status()


def journal_filters():
    names = {"schema": "TRELLIS_DETACH_JOURNAL_SCHEMA", "invariants": "TRELLIS_DETACH_JOURNAL_INVARIANTS",
             "owner": "TRELLIS_OWNER_SCHEMA"}
    filters = {key: os.environ.get(name, "") for key, name in names.items()}
    if not all(filters.values()):
        refuse(2)
    return filters


# --- locks (spec 075 T3): the checkout lock and the worktree attachment lock,
# the same files, owner records, process-birth tokens and reclaim rules as the
# shell (`_attachment_checkout_lock_*`, `_attachment_lock_*` in attachment.sh),
# so a shell and this process contend for one lock. Statuses as the shell's:
# 0 done, 1 I/O, 2 shape, 3 held by a live process, 4 malformed.

PROC_PIDTBSDINFO = 3
ESRCH = 3


def process_birth(pid):
    # trellis_process_birth: the 28-column `ps -o lstart=` token (libproc on
    # Darwin), as the shell's $(...) captured it (trailing newlines dropped).
    # None for every failure: indeterminate, never "dead".
    import ctypes
    import subprocess
    import time
    if not isinstance(pid, int) or pid < 1 or pid > 2147483647:
        return None
    if sys.platform == "darwin":
        class ProcBsdInfo(ctypes.Structure):
            _fields_ = [
                ("head", ctypes.c_uint32 * 12),
                ("pbi_comm", ctypes.c_char * 16),
                ("pbi_name", ctypes.c_char * 32),
                ("tail", ctypes.c_uint32 * 5),
                ("pbi_nice", ctypes.c_int32),
                ("pbi_start_tvsec", ctypes.c_uint64),
                ("pbi_start_tvusec", ctypes.c_uint64),
            ]
        try:
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            proc_pidinfo = libproc.proc_pidinfo
        except (OSError, AttributeError):
            return None
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                 ctypes.POINTER(ProcBsdInfo), ctypes.c_int]
        proc_pidinfo.restype = ctypes.c_int
        info = ProcBsdInfo()
        written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info))
        if written != ctypes.sizeof(info) or info.head[3] != pid or info.pbi_start_tvsec < 1:
            return None
        try:
            token = time.strftime("%a %b %e %H:%M:%S %Y", time.localtime(info.pbi_start_tvsec))
        except (OSError, OverflowError, ValueError):
            return None
        if not token or len(token) > 28:
            return None
        return token.ljust(28)
    try:
        output = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=dict(os.environ, LC_ALL="C")).stdout
    except OSError:
        return None
    token = os.fsdecode(output).rstrip("\n")
    return token or None


def process_live(pid):
    # `kill -0`: a process we may not signal is still alive.
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def make_holder_dir(locks, prefix):
    # `mktemp -d "$locks/<prefix>XXXXXX"`, then chmod 700.
    alphabet = string.ascii_letters + string.digits
    generator = random.SystemRandom()
    for _ in range(100):
        path = locks + "/" + prefix + "".join(generator.choice(alphabet) for _ in range(6))
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            continue
        os.chmod(path, 0o700)
        return path
    raise OSError("no unique lock holder name")


def write_private_json(path, text):
    # _attachment_write_json: never through a symlink, a canonical parent, a
    # private temporary renamed into place.
    if is_link(path):
        return 3
    if not canonical_dir_kept(os.path.dirname(path)):
        return 1
    alphabet = string.ascii_letters + string.digits
    temporary = path + ".tmp." + "".join(random.SystemRandom().choice(alphabet) for _ in range(6))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        data = (text + "\n").encode("utf-8")
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
    except BaseException:
        os.close(fd)
        os.unlink(temporary)
        raise
    os.close(fd)
    os.rename(temporary, path)
    return 0


def compact(record):
    # jq -cn: the given key order, compact separators.
    return json.dumps(record, separators=(",", ":"), ensure_ascii=False)


class HeldLock(object):
    def __init__(self, link, holder):
        self.link = link
        self.holder = holder
        self.publisher_fd = None

    def release(self):
        # _attachment_lock_release / _attachment_checkout_lock_release
        if is_link(self.link):
            if os.path.dirname(self.holder) + "/" + os.path.basename(os.readlink(self.link)) != self.holder:
                return 1
            os.unlink(self.link)
        for name in ("owner.json", "publisher.lock"):
            try:
                os.unlink(self.holder + "/" + name)
            except FileNotFoundError:
                pass
        if self.publisher_fd is not None:
            os.close(self.publisher_fd)
            self.publisher_fd = None
        try:
            os.rmdir(self.holder)
        except OSError:
            return 1
        return 0


def worktree_lock_path(home, checkout, worktree):
    return "%s/state/locks/attachment-%s-%s.lock" % (home, checkout, worktree)


def worktree_lock_prefix(checkout, worktree):
    return ".attachment-%s-%s.holder-" % (checkout, worktree)


def checkout_lock_path(home, checkout):
    return "%s/state/locks/attachment-checkout-%s.lock" % (home, checkout)


def checkout_lock_prefix(checkout):
    return ".attachment-checkout-%s.holder-" % checkout


def publish_holder(link, holder, record):
    # owner.json, then the link; a lost race removes the holder (3).
    status = write_private_json(holder + "/owner.json", compact(record))
    if status:
        os.rmdir(holder)
        return status
    try:
        os.symlink(os.path.basename(holder), link)
    except OSError:
        os.unlink(holder + "/owner.json")
        os.rmdir(holder)
        return 3
    return 0


def worktree_lock_acquire(home, checkout, worktree, attachment):
    # _attachment_lock_acquire. The holder also keeps publisher.lock flocked
    # for its whole life, as the 1.5.1 commit program did, so a recover by an
    # older release never reclaims a lock this live process holds.
    import fcntl
    link = worktree_lock_path(home, checkout, worktree)
    if exists(link):
        return 3, None
    pid = os.getpid()
    birth = process_birth(pid)
    if not birth:
        return 1, None
    locks = home + "/state/locks"
    holder = make_holder_dir(locks, "%s%s.%d." % (worktree_lock_prefix(checkout, worktree), attachment, pid))
    status = publish_holder(link, holder, {"checkout_id": checkout, "worktree_id": worktree,
                                           "attachment_id": attachment, "pid": pid, "process_birth": birth})
    if status:
        return status, None
    held = HeldLock(link, holder)
    fd = os.open(holder + "/publisher.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        held.release()
        return 3, None
    held.publisher_fd = fd
    return 0, held


def checkout_lock_acquire(home, checkout, common):
    # _attachment_checkout_lock_acquire
    if not canonical_dir_kept(common) or sha256_text(common) != checkout:
        return 2, None
    link = checkout_lock_path(home, checkout)
    if exists(link):
        return 3, None
    pid = os.getpid()
    birth = process_birth(pid)
    if not birth:
        return 1, None
    holder = make_holder_dir(home + "/state/locks", "%s%d." % (checkout_lock_prefix(checkout), pid))
    status = publish_holder(link, holder, {"checkout_id": checkout, "git_common_dir": common,
                                           "pid": pid, "process_birth": birth})
    if status:
        return status, None
    return 0, HeldLock(link, holder)


def read_holder(home, link, prefix):
    # The holder a lock link names, or a status: 0 no lock, 4 malformed.
    if not exists(link):
        return 0, None, None
    if not is_link(link):
        return 4, None, None
    try:
        target = os.readlink(link)
    except OSError:
        return 4, None, None
    if "/" in target or target in (".", "..") or not target.startswith(prefix):
        return 4, None, None
    holder = home + "/state/locks/" + target
    metadata = holder + "/owner.json"
    info = lstat_or_none(metadata)
    if not is_dir(holder) or info is None or not stat.S_ISREG(info.st_mode):
        return 4, None, None
    if format(stat.S_IMODE(info.st_mode) & 0o777, "o") != "600":
        return 4, None, None
    try:
        with open(metadata, "rb") as handle:
            record = json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError):
        return 4, None, None
    return None, holder, record


def stale(record):
    # The recorded process is gone, or its pid now names another process.
    pid = record["pid"]
    if not process_live(pid):
        return 0
    birth = process_birth(pid)
    if not birth:
        return 4
    return 3 if birth == record["process_birth"] else 0


def publisher_idle(path):
    # _attachment_publisher_idle
    import fcntl
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return 1
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 3
    except OSError:
        return 1
    finally:
        os.close(fd)
    return 0


def valid_lock_record(record, keys):
    return (isinstance(record, dict) and sorted(record) == sorted(keys)
            and isinstance(record.get("pid"), int) and not isinstance(record.get("pid"), bool)
            and record["pid"] > 0
            and isinstance(record.get("process_birth"), str) and len(record["process_birth"]) > 0)


def worktree_lock_reclaim(home, checkout, worktree, attachment):
    # _attachment_lock_reclaim
    link = worktree_lock_path(home, checkout, worktree)
    status, holder, record = read_holder(home, link, worktree_lock_prefix(checkout, worktree))
    if status is not None:
        return status
    if not (valid_lock_record(record, ["attachment_id", "checkout_id", "pid", "process_birth", "worktree_id"])
            and record["checkout_id"] == checkout and record["worktree_id"] == worktree
            and isinstance(record["attachment_id"], str)):
        return 4
    if record["attachment_id"] != attachment:
        return 3
    status = stale(record)
    if status:
        return status
    publisher = holder + "/publisher.lock"
    if exists(publisher):
        if not is_file(publisher):
            return 4
        status = publisher_idle(publisher)
        if status:
            return status
    os.unlink(link)
    os.unlink(holder + "/owner.json")
    try:
        os.unlink(publisher)
    except FileNotFoundError:
        pass
    os.rmdir(holder)
    return 0


def checkout_lock_reclaim(home, checkout, common):
    # _attachment_checkout_lock_reclaim
    if not canonical_dir_kept(common) or sha256_text(common) != checkout:
        return 2
    link = checkout_lock_path(home, checkout)
    status, holder, record = read_holder(home, link, checkout_lock_prefix(checkout))
    if status is not None:
        return status
    if not (valid_lock_record(record, ["checkout_id", "git_common_dir", "pid", "process_birth"])
            and record["checkout_id"] == checkout and record["git_common_dir"] == common):
        return 4
    status = stale(record)
    if status:
        return status
    os.unlink(link)
    os.unlink(holder + "/owner.json")
    os.rmdir(holder)
    return 0


def checkout_lock_wait(home, checkout, common, sleep=None, tries=3600):
    # attachment_checkout_lock_wait: reclaim (retrying a malformed read for
    # two seconds), then acquire; a held lock is waited for 900 s.
    import time
    sleep = sleep or time.sleep
    for attempt in range(tries + 1):
        for malformed in range(11):
            status = checkout_lock_reclaim(home, checkout, common)
            if status != 4 or malformed == 10:
                break
            sleep(0.2)
        if status == 0:
            status, held = checkout_lock_acquire(home, checkout, common)
            if status == 0:
                return 0, held
        if status != 3 or attempt == tries:
            return status, None
        sleep(0.25)
    return 3, None


def main(argv):
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    try:
        if argv[:1] == ["verify"] and len(argv) == 2:
            verify_owner(argv[1])
        elif argv == ["verify-owners"]:
            verify_owners()
        elif argv[:1] == ["journal-valid"] and len(argv) == 2:
            return journal_valid(argv[1], journal_filters())
        elif argv[:1] == ["renders"] and len(argv) == 5:
            action, journal_path, holder, owner_pid = argv[1:]
            hold_transaction_lock(holder, int(owner_pid))
            DetachCommit(action, journal_path, int(owner_pid)).run_renders()
        elif argv[:1] == ["finish"] and len(argv) == 6:
            action, journal_path, holder, owner_pid, home = argv[1:]
            hold_transaction_lock(holder, int(owner_pid))
            DetachCommit(action, journal_path, int(owner_pid)).finish(home, journal_filters())
        elif argv[:1] == ["commit"] and len(argv) == 6:
            action, journal_path, holder, owner_pid, home = argv[1:]
            hold_transaction_lock(holder, int(owner_pid))
            DetachCommit(action, journal_path, int(owner_pid)).commit_all(home, journal_filters())
        else:
            return 2
    except Stop as stop:
        return stop.status
    except OSError as error:
        sys.stderr.write("trellis attachment: detach stopped: %s\n" % error)
        return 1
    except (ValueError, KeyError, TypeError, AttributeError):
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
