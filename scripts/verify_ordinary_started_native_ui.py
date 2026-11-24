#!/usr/bin/env python3
"""Four separately claimed stages around one production native UI roundtrip.

Offline by default. Status writes happen only in a packaged KOReader worker;
independent host observations and distinct durable claims gate every stage.
"""
import argparse
import json
from pathlib import Path
import resource
import subprocess
import tempfile

from native_direct_time_trial_store import Intent
from ordinary_reading_status_trial import STAGES, request, run
from personal_upload_trial import hash_value
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_cloud_group_trial import no_other_pending
from verify_ordinary_reading_status import ScopedNative, execute as protocol_execute, observation
from verify_owner_started_change_preview import decode_runner
from verify_shelf_flags import WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session


def intent(name):
    backend = MacKeychain(service='org.codex.weread.ordinary-started-native-ui-' + name + '-v1', account=ACCOUNT)
    path = Path(tempfile.gettempdir()) / ('codex-ordinary-started-native-ui-' + name + '-' + ACCOUNT + '.lock')
    return Intent(backend=backend, lock=lambda: project_lock(path))


def stores():
    return (intent('plan'), {name: intent(name) for name in STAGES},
            {name: intent(name + '-proof') for name in STAGES},
            {name: intent(name + '-ui-proof') for name in ('mark', 'restore')})


def check_ui_proofs(stage, selection, proofs, ui_proofs):
    required = () if stage in ('preview', 'prepare', 'add', 'mark') else ('mark',) if stage == 'restore' else ('mark', 'restore')
    for name in ('mark', 'restore'):
        value, _ = ui_proofs[name].read()
        if name not in required:
            if value is not None: raise ValueError('started_native_ui/unexpected_proof')
            continue
        prior, _ = proofs[name].read()
        if (not value or value['phase'] != 'claimed' or value['plan']['selection'] != selection
                or value['plan']['record'] != {'kind': name + '_native_ui_verified'} or value['plan']['body'] != {}
                or not prior or prior['phase'] != 'claimed' or prior['plan']['selection'] != selection
                or prior['plan']['record'].get('kind') != name + '_observed'
                or value['plan']['baseline'] != prior['plan']['baseline']):
            raise ValueError('started_native_ui/proof')


class ScopedUI(ScopedNative):
    def __init__(self, grant, selection, actions, proofs, current, web, command):
        super().__init__(grant, selection, actions, proofs, current)
        self.web, self.command, self.ui = web, command, None

    def send(self, stage, path, plan):
        if stage not in ('mark', 'restore') or not self.command:
            raise ValueError('started_native_ui/stage')
        expected_path, body = request(stage, self.selection['book_id'])
        if (self.current() is not True or self.attempts or path != expected_path or plan['selection'] != self.selection
                or plan['record'] != {'kind': stage} or plan['body'] != body
                or self.actions[stage].read()[0] is not None or self.proofs[stage].read()[0] is not None):
            raise ValueError('started_native_ui/scope')
        shelf = self.get('shelf');point = self.get('progress')
        if self.current() is not True or hash_value(observation(self, self.web, self.selection)) != plan['baseline']['snapshot_hash']:
            raise ValueError('started_native_ui/changed')
        data = dict(credentials=self.grant, book_id=self.selection['book_id'], shelf=shelf, progress=point,
                    desired=stage == 'mark', armed=True)
        encoded = json.dumps(data, ensure_ascii=False).encode()
        if len(encoded) > 2 * 1024 * 1024:
            raise ValueError('started_native_ui/size')
        # The permanent host claim precedes the isolated process and its SQLite claim.
        self.actions[stage].claim(plan);self.attempts += 1
        child = subprocess.run(self.command, input=encoded, capture_output=True, timeout=180)
        self.ui = decode_runner(child.stdout, child.returncode, armed=True)
        return None  # The independent readback, not an unrecognized receipt, decides the state.


def execute(saved, grant, web, plan_store, actions, proofs, ui_proofs, stage, command=None):
    if stage not in ('preview', 'prepare', 'audit') + STAGES:
        raise ValueError('started_native_ui/stage')
    if (stage in ('mark', 'restore')) != bool(command):
        raise ValueError('started_native_ui/command')
    if stage in ('preview', 'prepare'):
        check_ui_proofs(stage, None, proofs, ui_proofs)
        return protocol_execute(saved, grant, web, plan_store, actions, proofs, stage)
    value, _ = plan_store.read()
    if not value or value['phase'] != 'claimed': raise ValueError('started_native_ui/plan')
    plan = value['plan'];selection = plan['selection']
    if (plan['record'] != {'kind': 'plan'} or plan['body'] != {} or selection['owner'] != saved['vid']
            or selection['grant_hash'] != hash_value(grant)):
        raise ValueError('started_native_ui/plan')
    check_ui_proofs(stage, selection, proofs, ui_proofs)
    if stage not in ('mark', 'restore'):
        return protocol_execute(saved, grant, web, plan_store, actions, proofs, stage)
    native_store, web_store = NativeSessionStore(), SessionStore()
    def current():
        return native_store.load(saved['vid']) == grant and web_store.load() == saved and no_other_pending()
    native = ScopedUI(grant, selection, actions, proofs, current, web, command)
    result = run(stage, plan, actions, proofs, current, lambda: observation(native, web, selection), native.send)
    result.update(stage=stage, data_posts=native.attempts)
    if result['result'] != 'OBSERVED' or native.ui is None:
        result.update(result='UNVERIFIED', native_ui_verified=False)
        return result
    proof, _ = proofs[stage].read()
    if not proof or proof['phase'] != 'claimed' or current() is not True:
        raise ValueError('started_native_ui/proof')
    ui_proofs[stage].claim(dict(selection=selection, record={'kind': stage + '_native_ui_verified'}, body={},
                                baseline=proof['plan']['baseline']))
    result.update(native_ui_verified=True, native_ui=native.ui)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--stage', choices=('preview', 'prepare', 'audit') + STAGES)
    parser.add_argument('--ui-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if (args.saved_session != bool(args.stage) or args.stage in ('mark', 'restore') and not args.ui_command
            or args.ui_command and args.stage not in ('mark', 'restore')):
        parser.error('saved session requires one stage; mark and restore require the armed UI command last')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'data_posts': 0}));return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = grant = web = store = None
    try:
        store = SessionStore();saved = store.load();grant = NativeSessionStore().load(saved['vid'])
        web = WebFlagsProbe();web.vid = saved['vid']
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        web.verify_account()
        report = execute(saved, grant, web, *stores(), args.stage, args.ui_command)
    except Exception:
        report = {'result': 'UNVERIFIED', 'stage': args.stage,
                  'data_posts': None if args.stage in STAGES else 0, 'no_automatic_replay': True}
    finally:
        if web and saved and store and web.authenticated:
            try: report['refreshed_web_session_saved'] = save_refreshed_web_session(store, saved, web)
            except Exception: report.update(result='UNVERIFIED', session_preservation_failed=True)
        if web: web.close()
        if grant: grant.clear()
        if saved: saved.clear()
    print(json.dumps(report, indent=2))
    return int(report['result'] not in ('READ_ONLY_PREVIEW', 'PREPARED', 'OBSERVED', 'RESTORED_READ_ONLY'))


if __name__ == '__main__':
    raise SystemExit(main())
