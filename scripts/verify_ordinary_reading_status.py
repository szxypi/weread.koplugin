#!/usr/bin/env python3
"""Bounded ordinary-book status experiment; offline unless explicitly invoked.

Each stage has its own permanent claim and independently verified proof.
Reports contain fixed statuses only; credentials and private records stay in
memory or the existing local Keychain.
"""
import argparse
import json
from pathlib import Path
import resource
import tempfile
from urllib.parse import urlencode

from annotation_experiment_model import marks_state, thoughts_state
from cloud_group_contract import project
from cloud_group_trial import _cross_channel
from finish_change_contract import flags
from native_direct_time_trial_store import Intent
from ordinary_reading_status_trial import STAGES, progress, request, run, strip
from personal_upload_trial import hash_value
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_cloud_group_trial import FULL_SHELF, no_other_pending
from verify_eink_login import BASE, NativeProbe
from verify_native_discovery import DiscoveryProbe
from verify_owner_shelf_membership import prepare as select_book
from verify_shelf_flags import WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session


def intent(name):
    backend = MacKeychain(service='org.codex.weread.ordinary-reading-status-' + name + '-v1', account=ACCOUNT)
    path = Path(tempfile.gettempdir()) / ('codex-ordinary-reading-status-' + name + '-' + ACCOUNT + '.lock')
    return Intent(backend=backend, lock=lambda: project_lock(path))


def stores():
    return intent('plan'), {stage: intent(stage) for stage in STAGES}, {stage: intent(stage + '-proof') for stage in STAGES}


class ScopedNative(NativeProbe):
    def __init__(self, grant, selection, actions, proofs, current, opener=None):
        super().__init__(opener)
        self.grant, self.selection, self.actions, self.proofs, self.current = grant, selection, actions, proofs, current
        self.attempts = 0

    def request(self, *args, **kwargs):
        raise ValueError('ordinary_reading/scope')

    def get(self, kind):
        identity = self.selection['book_id']
        paths = {'shelf': FULL_SHELF,
                 'progress': BASE + '/book/getProgress?' + urlencode({'bookId': identity}),
                 'marks': BASE + '/book/bookmarklist?' + urlencode({'bookId': identity, 'synckey': 0}),
                 'thoughts': BASE + '/review/list?' + urlencode({'bookId': identity, 'listType': 11,
                             'listMode': 0, 'mine': 1, 'synckey': 0, 'count': 20})}
        if self.current() is not True or kind not in paths:
            raise ValueError('ordinary_reading/read_scope')
        return super().request(kind, paths[kind], credentials=self.grant)

    def send(self, stage, path, plan):
        expected_path, body = request(stage, self.selection['book_id'])
        if (self.current() is not True or self.attempts or path != expected_path or plan['selection'] != self.selection
                or plan['record'] != {'kind': stage} or plan['body'] != body
                or self.actions[stage].read()[0] is not None or self.proofs[stage].read()[0] is not None):
            raise ValueError('ordinary_reading/write_scope')
        index = STAGES.index(stage)
        for name in STAGES[:index]:
            action, _ = self.actions[name].read()
            proof, _ = self.proofs[name].read()
            if (not action or action['phase'] != 'claimed' or action['plan']['selection'] != self.selection
                    or action['plan']['record'] != {'kind': name} or action['plan']['body'] != request(name, self.selection['book_id'])[1]
                    or not proof or proof['phase'] != 'claimed' or proof['plan']['selection'] != self.selection
                    or proof['plan']['record'].get('kind') != name + '_observed'
                    or name == 'add' and proof['plan']['record'].get('acknowledged') is not True):
                raise ValueError('ordinary_reading/write_scope')
        if any(self.actions[name].read()[0] is not None or self.proofs[name].read()[0] is not None for name in STAGES[index+1:]):
            raise ValueError('ordinary_reading/write_scope')
        self.actions[stage].claim(plan)
        self.attempts += 1
        return super().request('write', BASE + path, body=body, credentials=self.grant)


def observation(native, web, selection):
    identity, owner = selection['book_id'], selection['owner']
    web.verify_account()
    native_shelf = native.get('shelf')
    web_shelf = web.request('shelf', 'https://weread.qq.com/web/shelf/sync')
    if not _cross_channel(project(native_shelf), project(web_shelf)):
        raise ValueError('ordinary_reading/channels')
    native_present, native_other = strip(native_shelf, identity)
    web_present, web_other = strip(web_shelf, identity)
    if native_present != web_present:
        raise ValueError('ordinary_reading/membership')
    marks = marks_state(native.get('marks'), identity, owner)
    thoughts = thoughts_state(native.get('thoughts'), identity, owner)
    return {'native_shelf': hash_value(native_other), 'web_shelf': hash_value(web_other),
            'marks': hash_value(marks), 'thoughts': hash_value(thoughts), 'present': native_present,
            'target_flags': {'native': flags(native_shelf).get(identity), 'web': flags(web_shelf).get(identity)}
                if native_present else None,
            'progress': progress(native.get('progress'), identity),
            'marks_empty': not marks['updated'] and not marks['chapters'], 'thoughts_empty': not thoughts}


def preflight(saved, grant, web, plan_store, actions, proofs, current):
    if (plan_store.read()[0] is not None or any(item.read()[0] is not None for item in (*actions.values(), *proofs.values()))
            or current() is not True):
        raise ValueError('ordinary_reading/consumed')
    selected, _ = select_book(grant, DiscoveryProbe())
    selection = {'owner': saved['vid'], 'book_id': selected['book_id'], 'grant_hash': hash_value(grant)}
    native = ScopedNative(grant, selection, actions, proofs, current)
    before = observation(native, web, selection)
    if before != observation(native, web, selection) or before['present'] or not before['marks_empty'] or not before['thoughts_empty']:
        raise ValueError('ordinary_reading/baseline')
    value, point = before['progress'], before['progress']['position']
    if (value['flag'] != 0 or value['start_time'] != 0 or point.get('chapterUid') != 0
            or point.get('chapterOffset') != 0 or point.get('progress') != 0
            or any(point.get(key) != 0 for key in ('readingTime', 'recordReadingTime', 'ttsTime'))
            or point.get('summary', '') != ''):
        raise ValueError('ordinary_reading/baseline')
    return {'selection': selection, 'record': {'kind': 'plan'}, 'body': {}, 'baseline': before}


def execute(saved, grant, web, plan_store, actions, proofs, stage, *, prepare_only=False):
    native_store, web_store = NativeSessionStore(), SessionStore()
    def current():
        return (native_store.load(saved['vid']) == grant and web_store.load() == saved and no_other_pending())
    report = {'result': 'UNVERIFIED', 'stage': stage, 'data_posts': 0, 'no_automatic_replay': True}
    if stage in ('preview', 'prepare'):
        plan = preflight(saved, grant, web, plan_store, actions, proofs, current)
        if stage == 'prepare' and not prepare_only:
            plan_store.claim(plan)
            report.update(result='PREPARED', baseline_verified=True)
        else:
            report.update(result='READ_ONLY_PREVIEW', baseline_verified=True)
        return report
    value, _ = plan_store.read()
    if not value or value['phase'] != 'claimed':
        raise ValueError('ordinary_reading/plan')
    plan = value['plan']
    selection = plan['selection']
    if (plan['record'] != {'kind': 'plan'} or plan['body'] != {} or selection['owner'] != saved['vid']
            or selection['grant_hash'] != hash_value(grant)):
        raise ValueError('ordinary_reading/plan')
    native = ScopedNative(grant, selection, actions, proofs, current)
    result = run(stage, plan, actions, proofs, current, lambda: observation(native, web, selection), native.send)
    result.update(stage=stage, data_posts=native.attempts)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--stage', choices=('preview', 'prepare') + STAGES)
    args = parser.parse_args(argv)
    if args.saved_session != bool(args.stage):
        parser.error('saved session requires one explicit stage')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'data_posts': 0}))
        return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = grant = web = store = None
    try:
        store = SessionStore()
        saved = store.load()
        grant = NativeSessionStore().load(saved['vid'])
        web = WebFlagsProbe()
        web.vid = saved['vid']
        for key, value in saved['cookies'].items():
            web.set_cookie(key, value)
        web.verify_account()
        report = execute(saved, grant, web, *stores(), args.stage)
    except Exception:
        report = {'result': 'UNVERIFIED', 'stage': args.stage, 'data_posts': 0, 'no_automatic_replay': True}
    finally:
        if web and saved and store and web.authenticated:
            try:
                report['refreshed_web_session_saved'] = save_refreshed_web_session(store, saved, web)
            except Exception:
                report.update(result='UNVERIFIED', session_preservation_failed=True)
        if web:
            web.close()
        if grant:
            grant.clear()
        if saved:
            saved.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in ('READ_ONLY_PREVIEW', 'PREPARED', 'OBSERVED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
