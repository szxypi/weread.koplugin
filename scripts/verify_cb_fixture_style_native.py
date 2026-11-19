#!/usr/bin/env python3
"""Four native style writes on one fresh self-authored imported book.

Offline by default. A durable four-slot intent and the owned upload receipt
bind every step; unexpected results retain the fixture and are never retried.
Only hashes and sanitized status are retained; source and credentials use pipes.
"""
import argparse
import json
from pathlib import Path
import resource
import secrets
import subprocess
import tempfile

from cb_fixture_style_trial import Intent, prepare
from highlight_trial_model import observe
from mark_style_trial_model import observe_change
from native_trial_pipe import Frames, reply, stop, write_initial
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from verify_cb_fixture_highlight_native import run as run_fixture

UPLOAD_SERVICE = 'org.codex.weread.cb-native-style-upload-v1'
INTENT_SERVICE = 'org.codex.weread.cb-native-style-intent-v1'


def stores():
    def backend(service): return MacKeychain(service=service, account=ACCOUNT)
    def lock(name):
        path = Path(tempfile.gettempdir()) / ('codex-cb-native-style-' + name + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return Journal(backend=backend(UPLOAD_SERVICE), lock=lock('upload')), Intent(backend=backend(INTENT_SERVICE), lock=lock('intent'))


class TrialFailure(ValueError):
    def __init__(self, stage):
        super().__init__('cb_native_style/runner'); self.stage = stage


def run_ui(command, payload, plan, body, baseline, intent, authority, read, *, armed=False):
    if type(armed) is not bool or not command or any(not isinstance(v, str) or not v for v in command):
        raise ValueError('cb_native_style/command')
    if intent.read() != (None, None) or not authority() or read() != baseline:
        raise ValueError('cb_native_style/preflight')
    value = dict(payload, styles=True, armed=armed, token=secrets.token_hex(16))
    receipt = intent.reserve(plan) if armed else None
    child = None; steps = 0; target = row = None
    try:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        write_initial(child.stdin, value); frames = Frames(child.stdout, value['token'], timeout=600)
        while True:
            kind, event = frames.next()
            if kind == 'RESULT': result = event; break
            if not authority(): raise ValueError('cb_native_style/ownership')
            if not armed:
                if steps or event != {'seq': 0, 'preview': body} or read() != baseline: raise ValueError('cb_native_style/dry')
                reply(child.stdin, {'seq': 0, 'ok': True}); steps = 1; continue
            state, stored = intent.read(); seq = event.get('seq')
            if (state is None or stored != receipt or state['plan'] != plan or set(event) != {'seq', 'created_id'}
                    or type(seq) is not int or seq != steps + 1 or seq not in (1, 2, 3, 4)):
                raise ValueError('cb_native_style/step')
            phase = {1: 'create_pending', 2: 'straight_pending', 3: 'wave_pending', 4: 'delete_pending'}[seq]
            if state['phase'] != phase or state['target'] != target: raise ValueError('cb_native_style/intent')
            current = read()
            if seq == 1:
                target = observe(baseline, current, body); row = current['marks']['updated'][target['id']]
            elif seq in (2, 3):
                target, row = observe_change(baseline, current, body, target, row, {2: 0, 3: 2}[seq])
            else:
                observe(baseline, current, dict(body, style=2), deleted=True, target=target)
            if event['created_id'] != target['id'] or not authority(): raise ValueError('cb_native_style/target')
            if seq < 4:
                receipt = intent.advance(receipt, {1: 'created', 2: 'straight', 3: 'wave'}[seq], target=target)
                if not authority() or observe(baseline, read(), dict(body, style=row['style']), target=target) != target:
                    raise ValueError('cb_native_style/changed')
                receipt = intent.advance(receipt, {1: 'straight_pending', 2: 'wave_pending', 3: 'delete_pending'}[seq])
            if not authority(): raise ValueError('cb_native_style/ownership')
            steps = seq; reply(child.stdin, dict(seq=seq, ok=True, created_id=event['created_id']))
        status = child.wait(timeout=15)
        expected = dict(result='PASS' if armed else 'DRY_RUN', profile_removed=True, installed_bytes_match=True,
                        stage=None, native_controls=True, writes=4 if armed else 0, fresh_offline=armed,
                        credentials_not_persisted=True)
        if result != expected:
            stage = result.get('stage') if isinstance(result, dict) else None
            if (not isinstance(stage, dict) or set(stage) != {'result', 'phase', 'failure_line'}
                    or stage['result'] not in ('PASS', 'UNVERIFIED', 'DRY_RUN')
                    or stage['phase'] not in ('decode', 'prepare', 'create', 'style0', 'style2', 'delete', 'reopen')
                    or type(stage['failure_line']) is not int or not 0 <= stage['failure_line'] <= 1000): stage = None
            raise TrialFailure(stage)
        if status or steps != (4 if armed else 1) or not authority(): raise ValueError('cb_native_style/result')
        if armed:
            observe(baseline, read(), dict(body, style=2), deleted=True, target=target)
            if not authority(): raise ValueError('cb_native_style/ownership')
            receipt = intent.advance(receipt, 'verified'); intent.finish(receipt)
            if intent.read() != (None, None): raise ValueError('cb_native_style/intent')
        elif read() != baseline: raise ValueError('cb_native_style/changed')
        return dict(result='PASS' if armed else 'DRY_RUN', writes=4 if armed else 0,
                    independent_readbacks=4 if armed else 0, profile_removed=True, fresh_offline=armed)
    finally:
        if child is not None: stop(child)
        value.clear()


def run(saved, session, native_store, grant, journal, intent, command, *, apply=False, **dependencies):
    def final_check(baseline, current, body):
        return observe(baseline, current, body, deleted=True) is None
    return run_fixture(saved, session, native_store, grant, journal, intent, command, apply=apply, prepare_fn=prepare,
                       native_writes=4, result_label='CB_NATIVE_STYLE_VERIFIED', final_check=final_check,
                       ui_runner=run_ui, **dependencies)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--apply', action='store_true'); parser.add_argument('--runner', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and not args.runner or args.runner and not args.saved_session:
        parser.error('saved session and runner required')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', native_writes_allocated=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = None
    try:
        session = SessionStore(); saved = session.load(); native = NativeSessionStore(); grant = native.load(saved['vid'])
        report = run(saved, session, native, grant, *stores(), args.runner, apply=args.apply)
    except Exception:
        report = dict(result='UNVERIFIED', phase='setup', native_writes_allocated=0)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report, ensure_ascii=False)); return int(report['result'] not in ('READ_ONLY_PREVIEW', 'CB_NATIVE_STYLE_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
