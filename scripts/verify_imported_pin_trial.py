#!/usr/bin/env python3
"""One account-bound imported-book pin and restore, with durable no-replay intents."""
import argparse
import json
from pathlib import Path
import re
import resource
import tempfile
from urllib.parse import urlencode

from finish_change_contract import flags
from imported_pin_trial import request, run, sample, target_id
from imported_pin_audit_binding import create as create_binding, permits as binding_permits
from cloud_group_trial import _cross_channel
from native_direct_time_trial_store import Intent
from personal_upload_trial import hash_value
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_eink_login import BASE, NativeProbe
from verify_native_thought_trial import other_pending
from verify_pin_preflight import reading_fingerprint
from verify_shelf_flags import WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session


def intents():
    result = {}
    for kind in ('pin', 'restore'):
        name = 'org.codex.weread.imported-cloud-pin-' + kind + '-v1'
        path = Path(tempfile.gettempdir()) / ('codex-imported-cloud-pin-' + kind + '-' + ACCOUNT + '.lock')
        result[kind] = Intent(backend=MacKeychain(service=name, account=ACCOUNT),
                              lock=lambda path=path: project_lock(path))
    return result


def execute(saved, grant, web, records, *, apply=False):
    report = {'result': 'UNVERIFIED', 'phase': 'preflight', 'writes_attempted': 0, 'authentication_posts': 0}
    probe = NativeProbe();session_store = SessionStore();native_store = NativeSessionStore()
    def current():
        return session_store.load() == saved and native_store.load(saved['vid']) == grant and not other_pending()
    def shelf_native():
        return probe.request('shelf', BASE + '/shelf/sync', credentials=grant)
    def shelf_web():
        return web.request('shelf', 'https://weread.qq.com/web/shelf/sync')
    def observe(target):
        if not target_id(target) or not current(): raise ValueError('imported_pin/scope')
        native = shelf_native();other = shelf_web()
        progress = probe.request('progress', BASE + '/book/getProgress?' + urlencode({'bookId': target}), credentials=grant)
        return {'native': native, 'web': other, 'progress': progress}
    try:
        if not current() or any(record.read()[0] is not None for record in records.values()):
            raise ValueError('imported_pin/consumed')
        native, other = shelf_native(), shelf_web()
        native_flags, other_flags = flags(native), flags(other)
        candidates = [identity for identity in sorted(set(native_flags) & set(other_flags)) if target_id(identity)
                      and native_flags[identity]['pinned'] == {'reason': 'missing'}
                      and other_flags[identity]['pinned'] == {'reason': 'missing'}]
        target = None
        for identity in candidates:
            url = BASE + '/book/getProgress?' + urlencode({'bookId': identity})
            first = probe.request('candidate_progress', url, credentials=grant)
            second = probe.request('candidate_progress', url, credentials=grant)
            if reading_fingerprint(first) == reading_fingerprint(second):
                target = identity;break
        if not target or not current(): raise ValueError('imported_pin/no_candidate')
        grant_hash = hash_value(grant);attempted = []
        def send(kind, body):
            if (kind not in ('pin', 'restore') or body != request(target, kind == 'pin') or not current()
                    or kind in attempted or (kind == 'restore' and attempted != ['pin'])):
                raise ValueError('imported_pin/scope')
            record, _raw = records[kind].read()
            if (not record or record['phase'] != 'claimed' or record['plan']['body'] != body
                    or record['plan']['record'] != {'kind': kind}
                    or record['plan']['selection'] != {'owner': saved['vid'], 'book_id': target, 'grant_hash': grant_hash}):
                raise ValueError('imported_pin/claim')
            attempted.append(kind)
            return probe.request('pin_write', BASE + '/shelf/top', body, grant)
        report = run(saved['vid'], target, grant_hash, observe, send, records, current, apply=apply)
        report['authentication_posts'] = 0
    except Exception:
        pass
    return report


def inspect(saved, grant, web, records, binding=None):
    """Read the consumed target only; a mismatch cannot grant another write."""
    pin, _ = records['pin'].read();restore, _ = records['restore'].read()
    if not pin or pin.get('phase') not in ('claimed', 'acknowledged', 'verified'):
        raise ValueError('imported_pin/record')
    plan = pin['plan'];selection = plan['selection'];target = selection.get('book_id')
    if (not isinstance(selection, dict) or set(selection) != {'owner', 'book_id', 'grant_hash'}
            or selection['owner'] != saved['vid'] or not target_id(target)
            or not isinstance(selection['grant_hash'], str) or not re.fullmatch(r'[a-f0-9]{64}', selection['grant_hash'])
            or selection['grant_hash'] != hash_value(grant)
            and (binding is None or not binding_permits(saved['vid'], grant, pin, restore, binding))):
        raise ValueError('imported_pin/record')
    def valid_record(record, kind):
        value = record.get('plan') if isinstance(record, dict) else None
        if not isinstance(value, dict) or set(value) != {'selection', 'record', 'body', 'baseline'}:
            return False
        baseline = value['baseline']
        fields = {'snapshot_hash'}
        if not isinstance(baseline, dict) or set(baseline) not in (fields, fields | {'native_hash', 'web_hash', 'progress_hash'}):
            return False
        return (all(isinstance(item, str) and re.fullmatch(r'[a-f0-9]{64}', item) for item in baseline.values())
                and value['selection'] == selection and value['record'] == {'kind': kind}
                and value['body'] == request(target, kind == 'pin'))
    if not valid_record(pin, 'pin') or (restore and (pin['phase'] != 'verified' or not valid_record(restore, 'restore'))):
        raise ValueError('imported_pin/record')
    store = SessionStore();native = NativeSessionStore();probe = NativeProbe()
    def current(): return store.load() == saved and native.load(saved['vid']) == grant
    def observe(identity):
        if identity != target or not current(): raise ValueError('imported_pin/scope')
        return {'native': probe.request('shelf', BASE + '/shelf/sync', credentials=grant),
                'web': web.request('shelf', 'https://weread.qq.com/web/shelf/sync'),
                'progress': probe.request('progress', BASE + '/book/getProgress?' + urlencode({'bookId': target}), credentials=grant)}
    first = sample(observe, current, target);second = sample(observe, current, target)
    if first != second: raise ValueError('imported_pin/unstable')
    baseline = plan['baseline'];restore_baseline = restore['plan']['baseline'] if restore else {}
    report = {'result': 'READ_ONLY_INSPECTED', 'account_data_writes': 0, 'stable': True,
              'pin_intent_phase': pin['phase'], 'restore_intent_phase': restore['phase'] if restore else 'absent',
              'native_pin_state': first['native_pin'], 'web_pin_state': first['web_pin'],
              'native_web_members_and_groups_match': _cross_channel(first['native'], first['web']),
              'native_web_flags_match': first['native']['flags'] == first['web']['flags'],
              'matches_original_snapshot': hash_value(first) == baseline['snapshot_hash'],
              'matches_pre_restore_snapshot': hash_value(first) == restore_baseline.get('snapshot_hash')}
    if {'native_hash', 'web_hash', 'progress_hash'} <= baseline.keys():
        report['original_components_match'] = {'native': hash_value(first['native']) == baseline['native_hash'],
                                               'web': hash_value(first['web']) == baseline['web_hash'],
                                               'progress': first['progress_hash'] == baseline['progress_hash']}
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    modes=parser.add_mutually_exclusive_group()
    modes.add_argument('--apply', action='store_true')
    modes.add_argument('--inspect', action='store_true')
    modes.add_argument('--bind-inspection', action='store_true')
    args = parser.parse_args(argv)
    if (args.apply or args.inspect or args.bind_inspection) and not args.saved_session: parser.error('mode requires --saved-session')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'writes_attempted': 0}));return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = grant = web = None;store = SessionStore();report = {'result': 'UNVERIFIED', 'writes_attempted': 0}
    path = Path(tempfile.gettempdir()) / ('codex-imported-cloud-pin-execution-' + ACCOUNT + '.lock')
    try:
        with project_lock(path):
            saved = store.load();grant = NativeSessionStore().load(saved['vid']);web = WebFlagsProbe();web.vid = saved['vid']
            for key, value in saved['cookies'].items(): web.set_cookie(key, value)
            web.verify_account();records=intents()
            binding=MacKeychain(service='org.codex.weread.imported-cloud-pin-inspection-v1',account=ACCOUNT)
            if args.bind_inspection:
                pin,_=records['pin'].read();restore,_=records['restore'].read()
                create_binding(saved['vid'],grant,pin,restore,binding)
                report={'result':'AUDIT_BINDING_VERIFIED','account_data_writes':0}
            else:
                report = inspect(saved, grant, web, records, binding) if args.inspect else execute(saved, grant, web, records, apply=args.apply)
            web.verify_account()
    except Exception:
        report['result'] = 'UNVERIFIED'
    finally:
        if web and saved and web.authenticated:
            try: report['web_session_saved'] = save_refreshed_web_session(store, saved, web)
            except Exception: report.update(result='UNVERIFIED', session_preservation_failed=True)
        if web: web.close()
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] in ('READ_ONLY_PREVIEW', 'READ_ONLY_INSPECTED', 'AUDIT_BINDING_VERIFIED', 'PASS') else 1


if __name__ == '__main__': raise SystemExit(main())
