"""Linux-only whole-reader crash supervision for synthetic runtime validation."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

from mock_weread import BOOK_ID, CHAPTERS, MockServer, chapter_html
from source_upload_candidate import project
from verify_source_coordinates import FilteredSource

CASES = ('before-dispatch', 'after-apply', 'before-readback')
KINDS = ('periodic', 'manual', 'close')


class ProcessLossServer(MockServer):
    """Hold one production request at a deterministic, local-only boundary."""

    def __init__(self, port, log_path, case, kind='periodic'):
        if case not in CASES or kind not in KINDS:
            raise ValueError('unknown process-loss case or kind')
        super().__init__(port, log_path)
        self.case = case
        self.kind = kind
        self.armed = False
        self.applied = False
        self.blocked = threading.Event()
        self.release = threading.Event()
        self.read_bodies = []
        self.arm_index = None

    def route(self, method, target, data):
        path = urlsplit(target).path
        if path == '/__process_loss_arm':
            if method != 'POST' or data != {'case': self.case, 'kind': self.kind} or self.arm_index is not None:
                raise ValueError('invalid process-loss barrier')
            self.arm_index = len(self.read_bodies)
            self.armed = True
            return 200, dict(ok=True)
        if path == '/web/book/read' and method == 'POST':
            self.read_bodies.append(data.copy())
            result = super().route(method, target, data)
            if self.armed and 'rt' in data:
                self.applied = True
                if self.case == 'after-apply':
                    self._hold()
            return result
        if path == '/web/book/getProgress' and self.armed and self.applied and self.case == 'before-readback':
            self._hold()
        return super().route(method, target, data)

    def _hold(self):
        self.armed = False
        self.blocked.set()
        if not self.release.wait(45):
            raise RuntimeError('process-loss supervisor did not release the request')


def enable_subreaper():
    # KOReader workers create separate process groups. Adopt and reap them
    # after killing the reader, instead of leaving zombies with container PID 1.
    if sys.platform != 'linux' or not Path('/proc/self/stat').is_file():
        raise RuntimeError('whole-reader crash validation requires Linux /proc')
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), 'could not enable child subreaping')


def session_members(session):
    members = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        pid = int(entry.name)
        try:
            if os.getsid(pid) == session:
                members.append(pid)
        except ProcessLookupError:
            pass
    return sorted(members)


def kill_reader_session(process):
    """Stop and SIGKILL this isolated reader session, including worker groups."""
    if process.poll() is not None:
        raise RuntimeError('reader exited before the crash boundary')
    session = process.pid
    if os.getsid(session) != session or session == os.getsid(0):
        raise RuntimeError('reader is not in its own isolated session')
    os.kill(session, signal.SIGSTOP)
    members = session_members(session)
    for pid in members:
        try:
            os.kill(pid, signal.SIGSTOP)
        except ProcessLookupError:
            pass
    # A stopped reader cannot create new workers. Stop any worker that forked
    # while the first snapshot was being collected before killing all groups.
    for pid in session_members(session):
        if pid not in members:
            members.append(pid)
            os.kill(pid, signal.SIGSTOP)
    for pid in [p for p in members if p != session] + [session]:
        try:
            if os.getsid(pid) == session:
                os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    assert process.wait(timeout=5) == -signal.SIGKILL
    deadline = time.monotonic() + 5
    while session_members(session):
        for pid in members:
            if pid == session:
                continue
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
        if time.monotonic() >= deadline:
            raise RuntimeError('reader workers were not fully reaped')
        time.sleep(.01)
    return members


def wait_boundary(process, root, server, timeout=120):
    deadline = time.monotonic() + timeout
    ready_path = root / 'evidence/process-loss-ready.json'
    child_path = root / 'evidence/process-loss-child.json'
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('reader exited before reaching the crash boundary')
        if ready_path.exists():
            ready = json.loads(ready_path.read_text())
            if ready['parent_pid'] != process.pid or ready['case'] != server.case or ready['kind'] != server.kind:
                raise RuntimeError('crash boundary belongs to another reader')
            if server.case == 'before-dispatch':
                return ready, None
            if server.blocked.is_set() and server.kind != 'periodic':
                return ready, None
            if server.blocked.is_set() and child_path.exists():
                child = json.loads(child_path.read_text())['pid']
                if child == process.pid or os.getsid(child) != process.pid:
                    raise RuntimeError('report worker escaped the isolated reader session')
                return ready, child
        time.sleep(.02)
    raise TimeoutError('reader did not reach the process-loss boundary')


def run_process_loss(runtime, fixture, environment, log, server, root):
    enable_subreaper()
    command = ['./luajit', str(fixture)]
    process = subprocess.Popen(command, cwd=runtime, env=environment, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        ready, worker = wait_boundary(process, root, server)
        killed = kill_reader_session(process)
    finally:
        if process.poll() is None:
            kill_reader_session(process)
        server.release.set()
    if worker is not None:
        assert worker in killed, 'report worker was not included in the actual kill'
    records = [json.loads(path.read_text()) for path in (root / 'profile').rglob('reading_state.json')]
    saved = [row for row in records if isinstance(row.get('source_dispatch'), dict)
             and row['source_dispatch']['id'] == ready['dispatch_id']]
    assert len(saved) == 1, 'whole-process loss did not retain exactly one dispatch journal'
    saved = saved[0]
    assert saved['source_dispatch']['kind'] == ('time' if server.kind == 'periodic' else 'position')
    assert saved['pending_upload_position']
    target = saved['source_dispatch']['position']
    source = saved['source_dispatch']['source_position']
    raw = chapter_html(int(target['chapter_uid']))
    model = FilteredSource(raw)
    assert hashlib.sha256(raw.encode()).hexdigest() == source['raw_sha256']
    assert source['chapter_offset'] == target['chapter_offset'] and target['chapter_offset'] in model.starts
    independent = project(raw, source, CHAPTERS, target['percent'])
    sent = server.read_bodies[server.arm_index:]
    updates = [body for body in sent if 'rt' in body]
    expected_updates = int(server.case != 'before-dispatch')
    assert len(updates) == expected_updates, 'unexpected report attempts at crash boundary'
    remote = server.get_progress(BOOK_ID)['book']
    if updates:
        assert updates[0]['rt'] == (30 if server.kind == 'periodic' else 0)
        assert remote['chapterOffset'] == target['chapter_offset'] == updates[0]['co']
        assert str(remote['chapterUid']) == str(target['chapter_uid'])
        assert updates[0]['ci'] == independent['chapter_idx'] and updates[0]['sm'] == independent['summary']
    else:
        assert remote['chapterOffset'] != target['chapter_offset'], 'unsent target did not differ from cloud'
    (root / 'evidence/process-loss-disk-snapshot.json').write_text(json.dumps(saved, indent=2) + '\n')
    before = len(server.read_bodies)
    result = subprocess.run(command, cwd=runtime,
                            env=dict(environment, WEREAD_PROCESS_LOSS_REOPEN='reconcile'),
                            stdout=log, stderr=subprocess.STDOUT, timeout=120)
    assert len(server.read_bodies) == before, 'reopening or comparison replayed the interrupted upload'
    if result.returncode:
        return result
    before_http = server.request_totals.copy()
    result = subprocess.run(command, cwd=runtime,
                            env=dict(environment, WEREAD_PROCESS_LOSS_REOPEN='final'),
                            stdout=log, stderr=subprocess.STDOUT, timeout=120)
    assert server.request_totals == before_http, 'final offline process contacted the service'
    if result.returncode:
        return result
    outcome = json.loads((root / 'evidence/process-loss-reopen.json').read_text())
    outcome.update(result='PASS', case=server.case, kind=server.kind, synthetic_only=True,
                   whole_reader_sigkill=True, report_worker_sigkill=worker is not None,
                   killed_processes=len(killed), reader_exit_code=process.returncode,
                   all_reader_processes_reaped=not session_members(process.pid),
                   dispatch_survived_process_loss=True, mock_position_updates=expected_updates,
                   independent_python_source_coordinate_verified=True,
                   duration_per_mock_update=30 if updates and server.kind == 'periodic' else 0,
                   reopened_data_posts=0, final_offline_http_requests=0,
                   real_account_requests=0, keychain_accesses=0)
    (root / 'evidence/process-loss-runtime.json').write_text(json.dumps(outcome, indent=2) + '\n')
    print('PASS: whole-reader SIGKILL, independent disk journal, fresh-process reconciliation:', server.kind, server.case)
    return result
