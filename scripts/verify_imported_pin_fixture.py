#!/usr/bin/env python3
"""One synthetic EPUB pin roundtrip with split state fingerprints and cleanup gates."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import re
import resource
import tempfile
from urllib.parse import urlencode

from cloud_group_contract import project
from cloud_group_fixture import Journal, binding
from cloud_group_nonempty_workflow import strip_fixture
from cloud_group_trial import _cross_channel
from imported_pin_trial import request, run as pin_roundtrip, sample
from imported_pin_audit_binding import create as create_binding, permits as binding_permits
from native_direct_time_trial_store import Intent
from personal_upload_trial import hash_value
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_format_trial import TargetReceipt
from verify_cloud_group_trial import no_other_pending
from verify_eink_login import BASE, NativeProbe
from verify_imported_pin_trial import intents as prior_intents
from verify_personal_upload_trial import Probe as UploadProbe
from verify_shelf_flags import WebFlagsProbe
from verify_synthetic_epub_upload import read_source, run as upload
from verify_translation_preflight import save_refreshed_web_session


def backend(name):
    return MacKeychain(service='org.codex.weread.imported-pin-fixture-' + name + '-v1', account=ACCOUNT)


def lock(name):
    path = Path(tempfile.gettempdir()) / ('codex-imported-pin-fixture-' + name + '-' + ACCOUNT + '.lock')
    return lambda: project_lock(path)


def stores():
    journal = Journal(backend=backend('upload'), lock=lock('upload'))
    receipt = TargetReceipt('epub', backend=backend('target'), scope='group-fixture')
    records = {name: Intent(backend=backend(name), lock=lock(name)) for name in ('baseline', 'pin', 'restore')}
    return journal, receipt, records


def difference(before, after, before_raw, after_raw):
    """Return fixed field names and booleans only; never identities or values."""
    result = {channel: {field: before[channel][field] != after[channel][field]
                        for field in ('members', 'flags', 'groups', 'albums')}
              for channel in ('native', 'web')}
    result['progress_changed'] = before['progress_hash'] != after['progress_hash']
    fields = {'chapterUid', 'chapterIdx', 'chapterOffset', 'progress', 'summary', 'readingTime',
              'recordReadingTime', 'ttsTime', 'isStartReading', 'startReadingTime', 'readUpdateTime',
              'updateTime', 'reading', 'readStatus', 'readingStatus', 'status', 'markStatus', 'finishReading'}
    changed = []
    for container in ('root', 'book'):
        left = before_raw if container == 'root' else before_raw.get('book', {})
        right = after_raw if container == 'root' else after_raw.get('book', {})
        if not isinstance(left, dict) or not isinstance(right, dict): continue
        for name in sorted(fields):
            if (name in left) != (name in right) or name in left and left[name] != right[name]:
                changed.append(container + '.' + name)
    result['observed_progress_fields_changed'] = changed
    return result


def execute(saved, native_store, web, journal, receipt, records, protected_target, *, apply=False,
            native=None, upload_probe=None, uploader=upload, content_reader=read_source, pending=no_other_pending):
    report = {'result': 'UNVERIFIED', 'phase': 'preflight', 'fixture_only': True, 'existing_book_writes': 0,
              'pin_posts_attempted': 0, 'fixture_notify_posts': 0, 'fixture_cleanup_posts': 0,
              'no_automatic_replay': True, 'authentication_posts': 0}
    grant = native_store.load(saved['vid']);native = native or NativeProbe();session = SessionStore()
    def current(): return session.load() == saved and native_store.load(saved['vid']) == grant and pending() is True
    def pair():
        if not current(): raise ValueError('imported_pin_fixture/session')
        return {'native': native.request('shelf', BASE + '/shelf/sync', credentials=grant),
                'web': web.request('shelf', 'https://weread.qq.com/web/shelf/sync')}
    try:
        if (journal.read()[0] is not None or receipt.backend.load() is not None
                or any(item.read()[0] is not None for item in records.values()) or not current()):
            raise ValueError('imported_pin_fixture/consumed')
        initial = pair();original = {key: project(value) for key, value in initial.items()}
        if not _cross_channel(original['native'], original['web']) or {key: project(value) for key, value in pair().items()} != original:
            raise ValueError('imported_pin_fixture/baseline')
        if apply:
            records['baseline'].claim({'selection': {'owner': grant['vid'], 'grant_hash': hash_value(grant)},
                'record': {'kind': 'fixture_shelf_baseline'}, 'body': {},
                'baseline': {key: hash_value(value) for key, value in original.items()}})
        source = {'verified': False};trial = None;attempted = []
        probe = upload_probe or UploadProbe(journal, lambda value: current() and value == grant)
        def content(target):
            source['verified'] = content_reader(saved, target) is True
            return source['verified']
        def gate(_journal, _token, _plan, target):
            nonlocal trial
            bound, _ = binding(journal, receipt.backend)
            if (bound['target'] != target or target == protected_target or bound['plan']['owner'] != grant['vid']
                    or bound['plan']['grant_sha256'] != hash_value(grant) or not current()): return False
            def observe(identity):
                fresh, _ = binding(journal, receipt.backend)
                if identity != target or fresh != bound or not current(): raise ValueError('imported_pin_fixture/binding')
                shelves = pair()
                if not _cross_channel(project(shelves['native']), project(shelves['web'])):
                    raise ValueError('imported_pin_fixture/channels')
                if any(strip_fixture(shelves[key], target) != original[key] for key in ('native', 'web')):
                    raise ValueError('imported_pin_fixture/unrelated')
                return {'native': shelves['native'], 'web': shelves['web'],
                        'progress': native.request('progress', BASE + '/book/getProgress?' + urlencode({'bookId': target}), credentials=grant)}
            if not source['verified']:
                trial = {'result': 'SOURCE_UNVERIFIED', 'writes_attempted': 0}
                report['trial'] = trial
                return current()
            before_raw = observe(target);before = sample(lambda _target: deepcopy(before_raw), current, target)
            if before != sample(observe, current, target): return False
            def send(kind, body):
                if (kind not in ('pin', 'restore') or kind in attempted or body != request(target, kind == 'pin')
                        or kind == 'restore' and attempted != ['pin'] or not current()):
                    raise ValueError('imported_pin_fixture/send')
                record, _ = records[kind].read();fresh, _ = binding(journal, receipt.backend)
                if (fresh != bound or not record or record['phase'] != 'claimed' or record['plan']['body'] != body
                        or record['plan']['record'] != {'kind': kind}
                        or record['plan']['selection'] != {'owner': grant['vid'], 'book_id': target, 'grant_hash': hash_value(grant)}):
                    raise ValueError('imported_pin_fixture/claim')
                if kind == 'pin' and sample(observe, current, target) != before:
                    raise ValueError('imported_pin_fixture/changed')
                attempted.append(kind)
                return native.request('pin_write', BASE + '/shelf/top', body, grant)
            trial = pin_roundtrip(grant['vid'], target, hash_value(grant), observe, send,
                                  {'pin': records['pin'], 'restore': records['restore']}, current, apply=True)
            report['trial'] = trial;report['pin_posts_attempted'] = len(attempted)
            if attempted:
                try:
                    raw_after = observe(target);after = sample(lambda _target: deepcopy(raw_after), current, target)
                    if after != sample(observe, current, target): raise ValueError('imported_pin_fixture/unstable')
                    report['component_changes'] = difference(before, after, before_raw['progress'], raw_after['progress'])
                    report['post_trial_native_marker'] = after['native_pin']
                    report['post_trial_web_marker'] = after['web_pin']
                except Exception:
                    report['component_diagnosis'] = 'unavailable'
            # Only fully confirmed pin/restoration, or no attempted pin, allows fixture deletion.
            return current() and (trial['result'] == 'PASS' or not attempted)
        result = uploader(probe, journal, grant, lambda value: current() and value == grant, content,
                          apply=apply, notify_receipt=receipt.record, cleanup_gate=gate)
        report.update(phase=result['phase'], upload_result=result['result'], fixture_notify_posts=result['notify_posts'],
                      fixture_cleanup_posts=result['cleanup_posts'], fixture_source_verified=result['source_verified'])
        if not apply and result['result'] == 'READ_ONLY_PREVIEW': report['result'] = 'READ_ONLY_PREVIEW'
        elif result['phase'] == 'restored':
            final = {key: project(value) for key, value in pair().items()}
            report['original_shelves_match'] = final == original
            report['result'] = 'PASS' if final == original and trial and trial['result'] == 'PASS' else 'FIXTURE_CLEANED_UNVERIFIED'
        elif trial:
            report['result'] = 'FIXTURE_RETAINED_UNVERIFIED'
    except Exception:
        report['reason'] = 'imported_pin_fixture/unavailable'
    finally:
        grant.clear()
    return report


def validate_receipts(saved, grant, journal, receipt, records, protected_target, binding=None):
    """Validate the original receipts before allowing any read-only audit."""
    state, _ = journal.read();raw = receipt.backend.load();target_receipt = json.loads(raw)
    base, _ = records['baseline'].read();pin, _ = records['pin'].read();restore, _ = records['restore'].read()
    target = state['target'] if state else None
    original_hash = pin['plan']['selection']['grant_hash'] if pin else None
    if not isinstance(original_hash, str) or not re.fullmatch(r'[a-f0-9]{64}', original_hash):
        raise ValueError('imported_pin_fixture/audit')
    if original_hash != hash_value(grant) and (binding is None or not binding_permits(saved['vid'], grant, pin, restore, binding)):
        raise ValueError('imported_pin_fixture/audit')
    if (not state or state['phase'] != 'restored' or target == protected_target
            or not isinstance(target_receipt, dict) or set(target_receipt) != {'schema','owner','attempt','target','plan_sha256'}
            or target_receipt['schema'] != 1 or target_receipt['owner'] != saved['vid']
            or target_receipt['attempt'] != state['attempt'] or target_receipt['target'] != target
            or target_receipt['plan_sha256'] != hash_value(state['plan']) or state['plan']['grant_sha256'] != original_hash
            or state['plan']['owner'] != saved['vid']
            or not base or base['phase'] != 'claimed'
            or base['plan']['selection'] != {'owner': saved['vid'], 'grant_hash': original_hash}
            or base['plan']['record'] != {'kind': 'fixture_shelf_baseline'} or base['plan']['body'] != {}
            or set(base['plan']['baseline']) != {'native', 'web'}
            or any(not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value)
                   for value in base['plan']['baseline'].values())):
        raise ValueError('imported_pin_fixture/audit')
    selection = {'owner': saved['vid'], 'book_id': target, 'grant_hash': original_hash}
    for kind, item in (('pin', pin), ('restore', restore)):
        if (not item or item['phase'] != 'verified' or item['plan']['selection'] != selection
                or item['plan']['record'] != {'kind': kind} or item['plan']['body'] != request(target, kind == 'pin')
                or set(item['plan']['baseline']) != {'snapshot_hash', 'native_hash', 'web_hash', 'progress_hash'}
                or any(not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value)
                       for value in item['plan']['baseline'].values())):
            raise ValueError('imported_pin_fixture/audit')
    if pin['plan']['baseline']['native_hash'] != restore['plan']['baseline']['native_hash'] \
            or pin['plan']['baseline']['web_hash'] != restore['plan']['baseline']['web_hash'] \
            or pin['plan']['baseline']['progress_hash'] != restore['plan']['baseline']['progress_hash']:
        raise ValueError('imported_pin_fixture/audit')
    return target, base, pin, restore


def audit(saved, native_store, web, journal, receipt, records, protected_target, *, native=None, pending=no_other_pending, binding=None):
    """Recheck both shelves and immutable receipts without any data writes."""
    grant = native_store.load(saved['vid']);session = SessionStore();native = native or NativeProbe()
    try:
        target, base, _pin, _restore = validate_receipts(saved, grant, journal, receipt, records, protected_target, binding)
        def read():
            if session.load() != saved or native_store.load(saved['vid']) != grant or pending() is not True:
                raise ValueError('imported_pin_fixture/session')
            pair = {'native': native.request('shelf', BASE + '/shelf/sync', credentials=grant),
                    'web': web.request('shelf', 'https://weread.qq.com/web/shelf/sync')}
            value = {key: project(source) for key, source in pair.items()}
            if any(target in row['members'] for row in value.values()) or not _cross_channel(value['native'], value['web']):
                raise ValueError('imported_pin_fixture/shelf')
            return value
        first = read();second = read()
        if first != second: raise ValueError('imported_pin_fixture/unstable')
        matches = {key: hash_value(value) == base['plan']['baseline'][key] for key, value in second.items()}
        return {'result': 'READ_ONLY_RESTORED' if all(matches.values()) else 'READ_ONLY_SNAPSHOT_CHANGED',
                'account_data_writes': 0, 'fixture_absent_both_channels': True, 'two_stable_readbacks': True,
                'native_web_members_and_groups_match': True, 'original_shelf_snapshots_match': matches,
                'pin_and_restore_receipts_verified': True}
    finally:
        grant.clear()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session', action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--apply', action='store_true');mode.add_argument('--audit', action='store_true');mode.add_argument('--bind-audit', action='store_true')
    args = parser.parse_args(argv)
    if (args.apply or args.audit or args.bind_audit) and not args.saved_session: parser.error('mode requires --saved-session')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'account_data_writes': 0}));return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0));saved = web = None;store = SessionStore()
    report = {'result': 'UNVERIFIED', 'phase': 'preflight', 'existing_book_writes': 0}
    execution_lock = Path(tempfile.gettempdir()) / ('codex-imported-pin-fixture-execution-' + ACCOUNT + '.lock')
    try:
        with project_lock(execution_lock):
            saved = store.load();web = WebFlagsProbe();web.vid = saved['vid']
            for key, value in saved['cookies'].items(): web.set_cookie(key, value)
            web.verify_account();journal, receipt, records = stores()
            prior, _ = prior_intents()['pin'].read();protected = prior['plan']['selection']['book_id'] if prior else None
            binding=backend('audit-binding')
            if args.bind_audit:
                grant=NativeSessionStore().load(saved['vid'])
                try:
                    _target,_base,pin,restore=validate_receipts(saved,grant,journal,receipt,records,protected)
                    create_binding(saved['vid'],grant,pin,restore,binding)
                    report={'result':'AUDIT_BINDING_VERIFIED','account_data_writes':0}
                finally: grant.clear()
            elif args.audit:
                report=audit(saved,NativeSessionStore(),web,journal,receipt,records,protected,binding=binding)
            else:
                report=execute(saved,NativeSessionStore(),web,journal,receipt,records,protected,apply=args.apply)
            web.verify_account()
    except Exception:
        report['result'] = 'UNVERIFIED'
    finally:
        if web and saved and web.authenticated:
            try: report['web_session_saved'] = save_refreshed_web_session(store, saved, web)
            except Exception: report.update(result='UNVERIFIED', session_preservation_failed=True)
        if web: web.close()
        if saved: saved.clear()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] in ('READ_ONLY_PREVIEW', 'READ_ONLY_RESTORED', 'READ_ONLY_SNAPSHOT_CHANGED', 'AUDIT_BINDING_VERIFIED', 'PASS') else 1


if __name__ == '__main__': raise SystemExit(main())
