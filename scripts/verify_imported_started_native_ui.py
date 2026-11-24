#!/usr/bin/env python3
"""Isolated imported EPUB and two single-shot native started-status changes."""
import argparse
import json
from pathlib import Path
import re
import resource
import subprocess
import tempfile
from urllib.parse import urlencode

from annotation_experiment_model import marks_state, thoughts_state
from cloud_group_contract import project
from cloud_group_fixture import Journal, binding
from cloud_group_nonempty_workflow import strip_fixture
from cloud_group_trial import _cross_channel
from imported_started_ui_trial import run as run_status
from native_direct_time_trial_store import Intent
from ordinary_reading_status_trial import progress
from personal_upload_trial import hash_value
from reading_status_fixture_trial import OBSERVABLE, request, select, target_row
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import check as check_upload
from synthetic_format_trial import TargetReceipt
from verify_cloud_group_trial import no_other_pending
from verify_eink_login import BASE, NativeProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_reading_status_fixture import ScopedNative as FixtureProbe
from verify_shelf_flags import WebFlagsProbe
from verify_synthetic_epub_upload import read_source, run as upload
from verify_owner_started_change_preview import decode_runner
from verify_translation_preflight import save_refreshed_web_session


def backend(name):
    return MacKeychain(service='org.codex.weread.imported-started-native-ui-' + name + '-v1', account=ACCOUNT)


def lock(name):
    path = Path(tempfile.gettempdir()) / ('codex-imported-started-native-ui-' + name + '-' + ACCOUNT + '.lock')
    return lambda: project_lock(path)


def stores():
    return (Journal(backend=backend('upload'), lock=lock('upload')),
            TargetReceipt('epub', backend=backend('target'), scope='group-fixture'),
            {name: Intent(backend=backend(name), lock=lock(name)) for name in ('baseline', 'mark', 'mark-proof', 'restore', 'restore-proof')})


def selection(state, grant):
    return dict(owner=grant['vid'], target=state['target'], upload_attempt=state['attempt'],
                upload_plan_hash=hash_value(state['plan']), grant_hash=hash_value(grant))


def proof_matches(value, action, identity, kind):
    return (value and value['phase'] == 'claimed' and value['plan']['selection'] == identity
            and value['plan']['record'] == {'kind': kind + '_ui_observed'} and value['plan']['body'] == {}
            and isinstance(value['plan']['baseline'], dict) and set(value['plan']['baseline']) == {'snapshot_hash'}
            and isinstance(value['plan']['baseline']['snapshot_hash'], str)
            and re.fullmatch('[a-f0-9]{64}', value['plan']['baseline']['snapshot_hash']) is not None
            and action and action['phase'] == 'claimed' and action['plan']['selection'] == identity
            and action['plan']['record'] == {'kind': kind} and action['plan']['body'] == request(identity['target'], kind == 'restore')
            and isinstance(action['plan']['baseline'], dict) and set(action['plan']['baseline']) == {'snapshot_hash'}
            and isinstance(action['plan']['baseline']['snapshot_hash'], str)
            and re.fullmatch('[a-f0-9]{64}', action['plan']['baseline']['snapshot_hash']) is not None)


class ScopedUI(FixtureProbe):
    def __init__(self, grant, current, pending, journal, receipt, intents, command):
        super().__init__(grant, current, pending, journal, receipt, intents)
        self.command, self.observer, self.ui = command, None, {}

    def personal(self, target):
        state, _ = binding(self.upload, self.receipt.backend)
        if self.current() is not True or self.pending() is not True or state['target'] != target:
            raise ValueError('imported_started/target')
        bookmark = NativeProbe.request(self, 'marks', BASE + '/book/bookmarklist?' + urlencode({'bookId': target, 'synckey': 0}),
                                       credentials=self.grant)
        thoughts = NativeProbe.request(self, 'thoughts', BASE + '/review/list?' + urlencode({'bookId': target, 'listType': 11,
                                       'listMode': 0, 'mine': 1, 'synckey': 0, 'count': 20}), credentials=self.grant)
        return marks_state(bookmark, target, self.grant['vid']), thoughts_state(thoughts, target, self.grant['vid'])

    def send(self, kind, plan):
        if kind not in ('mark', 'restore') or not self.command or self.current() is not True or self.pending() is not True:
            raise ValueError('imported_started/scope')
        state, _ = binding(self.upload, self.receipt.backend);identity = selection(state, self.grant)
        if (state['plan']['owner'] != identity['owner'] or state['plan']['grant_sha256'] != identity['grant_hash']
                or plan.get('selection') != identity or plan.get('record') != {'kind': kind}
                or plan.get('body') != request(identity['target'], kind == 'restore') or self.attempts[kind]
                or self.intents[kind].read()[0] is not None or self.intents[kind+'-proof'].read()[0] is not None):
            raise ValueError('imported_started/scope')
        if kind == 'restore':
            prior, _ = self.intents['mark'].read();observed, _ = self.intents['mark-proof'].read()
            if not proof_matches(observed, prior, identity, 'mark') or observed['plan']['baseline'] != plan['baseline']:
                raise ValueError('imported_started/proof')
        shelf = self.shelf();point = self.progress(identity['target'])
        if self.current() is not True or hash_value(self.observer()) != plan['baseline']['snapshot_hash']:
            raise ValueError('imported_started/changed')
        data = dict(credentials=self.grant, book_id=identity['target'], shelf=shelf, progress=point,
                    desired=kind == 'mark', armed=True)
        encoded = json.dumps(data, ensure_ascii=False).encode()
        if len(encoded) > 2 * 1024 * 1024: raise ValueError('imported_started/size')
        self.intents[kind].claim(plan);self.attempts[kind] += 1
        dimensions = ['--width', '1264', '--height', '1680', '--dpi', '300'] if kind == 'mark' \
            else ['--width', '600', '--height', '800', '--dpi', '167']
        child = subprocess.run(self.command + dimensions + ['--armed'], input=encoded, capture_output=True, timeout=180)
        self.ui[kind] = decode_runner(child.stdout, child.returncode, armed=True)
        return True

    def proof(self, kind, identity, snapshot):
        state, _ = binding(self.upload, self.receipt.backend)
        action, _ = self.intents[kind].read()
        if (self.current() is not True or self.pending() is not True or selection(state, self.grant) != identity
                or kind not in self.ui or not action or action['phase'] != 'claimed'
                or action['plan']['selection'] != identity or action['plan']['record'] != {'kind': kind}
                or action['plan']['body'] != request(identity['target'], kind == 'restore')):
            raise ValueError('imported_started/proof')
        self.intents[kind+'-proof'].claim(dict(selection=identity, record={'kind': kind+'_ui_observed'}, body={},
                                              baseline={'snapshot_hash': hash_value(snapshot)}))


def execute(saved, native_store, web, journal, receipt, intents, *, apply=False, command=None):
    report = dict(result='UNVERIFIED', phase='preflight', fixture_only=True, existing_book_writes=0,
                  status_posts=0, fixture_cleanup_posts=0, no_automatic_replay=True)
    grant = native_store.load(saved['vid'])
    def current(): return SessionStore().load() == saved and native_store.load(saved['vid']) == grant
    native = ScopedUI(grant, current, no_other_pending, journal, receipt, intents, command)
    def shelves():
        web.verify_account();return {'native': native.shelf(), 'web': web.request('shelf', 'https://weread.qq.com/web/shelf/sync')}
    try:
        if (apply and not command or not apply and command or journal.read()[0] is not None or receipt.backend.load() is not None
                or any(item.read()[0] is not None for item in intents.values()) or no_other_pending() is not True):
            raise ValueError('imported_started/consumed')
        pair = shelves();original = {name: project(value) for name, value in pair.items()}
        if (not _cross_channel(original['native'], original['web'])
                or {name: project(value) for name, value in shelves().items()} != original):
            raise ValueError('imported_started/shelf')
        if apply:
            intents['baseline'].claim(dict(selection={'owner': grant['vid'], 'grant_hash': hash_value(grant)},
                record={'kind': 'shelf_baseline'}, body={}, baseline={name: hash_value(value) for name, value in original.items()}))
        probe = UploadProbe(journal, lambda value: current() and value == grant)
        trial_report = None;source = {'verified': False}
        def read_content(target):
            source['verified'] = read_source(saved, target) is True;return source['verified']
        def gate(_journal, _token, _plan, target):
            nonlocal trial_report
            state, _ = binding(journal, receipt.backend);identity = selection(state, grant)
            def observe():
                state_now, _ = binding(journal, receipt.backend)
                if state_now != state or current() is not True or no_other_pending() is not True:
                    raise ValueError('imported_started/binding')
                pair_now = shelves()
                if not _cross_channel(project(pair_now['native']), project(pair_now['web'])):
                    raise ValueError('imported_started/channels')
                for name in ('native', 'web'):
                    if strip_fixture(pair_now[name], target) != original[name]: raise ValueError('imported_started/unrelated')
                raw = native.progress(target);marks, thoughts = native.personal(target)
                return dict(native=target_row(pair_now['native'], target), web=target_row(pair_now['web'], target),
                            progress=progress(raw, target), observed=select(raw['book'], OBSERVABLE),
                            marks=hash_value(marks), thoughts=hash_value(thoughts),
                            marks_empty=not marks['updated'] and not marks['chapters'], thoughts_empty=not thoughts)
            native.observer = observe
            if source['verified']:
                trial_report = run_status(identity, observe, native.send, native.proof, current)
            else: trial_report = {'result': 'UNVERIFIED', 'status_posts': 0, 'phase': 'source'}
            report['status_posts'] = sum(native.attempts.values());report['trial'] = trial_report
            if trial_report['result'] != 'PASS' and trial_report['status_posts'] != 0: return False
            pair_after = shelves()
            return (current() and no_other_pending()
                    and all(strip_fixture(pair_after[name], target) == original[name] for name in ('native', 'web')))
        result = upload(probe, journal, grant, lambda value: current() and value == grant, read_content,
                        apply=apply, notify_receipt=receipt.record, cleanup_gate=gate)
        report.update(phase=result['phase'], upload_result=result['result'], fixture_cleanup_posts=result['cleanup_posts'],
                      fixture_notify_posts=result['notify_posts'], fixture_source_verified=result['source_verified'])
        if not apply and result['result'] == 'READ_ONLY_PREVIEW': report['result'] = 'READ_ONLY_PREVIEW'
        elif result['phase'] == 'restored' and {name: project(value) for name, value in shelves().items()} == original:
            report['full_shelf_restored'] = True
            report['result'] = 'PASS' if trial_report and trial_report['result'] == 'PASS' else 'FIXTURE_REMOVED_NO_STATUS_TEST'
            if native.ui: report['native_ui'] = native.ui
    except Exception:
        report['reason'] = 'imported_started/unavailable'
    finally:
        report['status_posts'] = sum(native.attempts.values());grant.clear()
    return report


def audit(saved, native_store, web, journal, receipt, intents):
    grant = native_store.load(saved['vid'])
    try:
        state, _ = journal.read();raw = receipt.backend.load()
        record = json.loads(raw) if isinstance(raw, bytes) and 0 < len(raw) <= 8192 else None
        base, _ = intents['baseline'].read()
        if (not state or state['phase'] != 'restored' or not isinstance(record, dict)
                or set(record) != {'schema', 'owner', 'attempt', 'target', 'plan_sha256'} or type(record['schema']) is not int or record['schema'] != 1
                or record['owner'] != saved['vid'] or record['attempt'] != state['attempt'] or record['target'] != state['target']
                or record['plan_sha256'] != hash_value(state['plan']) or not base or base['phase'] != 'claimed'
                or base['plan']['selection'] != {'owner': grant['vid'], 'grant_hash': hash_value(grant)}
                or base['plan']['record'] != {'kind': 'shelf_baseline'} or base['plan']['body'] != {}
                or state['plan']['owner'] != saved['vid'] or state['plan']['grant_sha256'] != hash_value(grant)):
            raise ValueError('imported_started/audit')
        identity = selection(state, grant)
        mark, _ = intents['mark'].read();mark_proof, _ = intents['mark-proof'].read()
        restore, _ = intents['restore'].read();restore_proof, _ = intents['restore-proof'].read()
        if (not proof_matches(mark_proof, mark, identity, 'mark') or not proof_matches(restore_proof, restore, identity, 'restore')
                or restore['plan']['baseline'] != mark_proof['plan']['baseline']
                or restore_proof['plan']['baseline'] != mark['plan']['baseline']):
            raise ValueError('imported_started/audit')
        probe = NativeProbe()
        def once():
            web.verify_account();native = probe.request('shelf', BASE+'/shelf/sync', credentials=grant)
            other = web.request('shelf', 'https://weread.qq.com/web/shelf/sync')
            check_upload(state['plan'], grant, native, state['target'], False)
            n, w = project(native), project(other)
            if not _cross_channel(n, w) or {'native': hash_value(n), 'web': hash_value(w)} != base['plan']['baseline']:
                raise ValueError('imported_started/audit')
        once();once()
        if SessionStore().load() != saved or native_store.load(saved['vid']) != grant or not no_other_pending():
            raise ValueError('imported_started/audit')
        return dict(result='RESTORED_READ_ONLY', account_data_writes=0, both_channels_match=True,
                    original_bookshelf_and_groups_restored=True, native_ui_roundtrip_proofs_verified=True)
    finally: grant.clear()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session', action='store_true')
    mode = parser.add_mutually_exclusive_group();mode.add_argument('--preview', action='store_true')
    mode.add_argument('--apply', action='store_true');mode.add_argument('--audit', action='store_true')
    parser.add_argument('--ui-command', nargs=argparse.REMAINDER);args = parser.parse_args(argv)
    if (args.saved_session != bool(args.preview or args.apply or args.audit) or args.apply != bool(args.ui_command)):
        parser.error('saved session requires a mode; apply requires the UI command last')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'status_posts': 0}));return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0));saved = web = store = None
    try:
        store = SessionStore();saved = store.load();web = WebFlagsProbe();web.vid = saved['vid']
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        web.verify_account();journal, receipt, intents = stores()
        report = audit(saved, NativeSessionStore(), web, journal, receipt, intents) if args.audit else \
            execute(saved, NativeSessionStore(), web, journal, receipt, intents, apply=args.apply, command=args.ui_command)
    except Exception:
        report = dict(result='UNVERIFIED', status_posts=None if args.apply else 0, reason='imported_started/unavailable')
    finally:
        if web and saved and store and web.authenticated:
            try: report['refreshed_web_session_saved'] = save_refreshed_web_session(store, saved, web)
            except Exception: report.update(result='UNVERIFIED', session_preservation_failed=True)
        if web: web.close()
        if saved: saved.clear()
    print(json.dumps(report, indent=2));return int(report['result'] not in ('READ_ONLY_PREVIEW','PASS','RESTORED_READ_ONLY'))


if __name__ == '__main__': raise SystemExit(main())
