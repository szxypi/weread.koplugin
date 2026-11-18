#!/usr/bin/env python3
"""One newly imported synthetic book through the native first-sync button.

Offline by default. A unique upload journal and claimed UI slot prohibit
replay. A read-only native dry run precedes the sole allowed position POST.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import tempfile
from urllib.parse import urlencode

from cb_cloud_position import observed, state
from cb_fixture_position import plan as position_plan
from cb_initial_fixture_flow import _classify
from cb_initial_fixture_intent import Intent
from cloud_group_contract import project
from cloud_group_nonempty_workflow import strip_fixture
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_fixture_position_trial import owned
from verify_cb_initial_fixture_trial import NativeRead, SourceRead
from verify_cb_native_time_guarded_dry import trusted_command
from verify_eink_login import BASE as NATIVE
from verify_personal_upload_trial import Probe as UploadProbe
from verify_source_coordinates import FilteredSource
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB, WebSourceProbe

UPLOAD_SERVICE = 'org.codex.weread.cb-first-native-ui-upload-v1'
UI_SERVICE = 'org.codex.weread.cb-first-native-ui-position-v1'


def stores():
    def lock(name):
        path = Path(tempfile.gettempdir()) / ('codex-cb-first-native-ui-' + name + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return (Journal(backend=MacKeychain(service=UPLOAD_SERVICE, account=ACCOUNT), lock=lock('upload')),
            Intent(backend=MacKeychain(service=UI_SERVICE, account=ACCOUNT), lock=lock('position')))


def ui_command():
    trusted = trusted_command()
    return trusted[:6] + ['env', '-u', 'WEREAD_FIXTURE_SYNTHETIC', '-u', 'WEREAD_FIXTURE_MOCK_PORT',
        'SDL_VIDEODRIVER=dummy', 'LD_LIBRARY_PATH=/validation/runtime/lib/koreader/libs',
        'python3', '/source/scripts/run_cb_initial_fixture_ui.py', '--koreader', '/validation/runtime/lib/koreader',
        '--candidate', trusted[-1], '--width', '1264', '--height', '1680', '--dpi', '300']


def run_ui(command, payload):
    child = subprocess.run(command, input=json.dumps(payload, ensure_ascii=False).encode(), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=780)
    if len(child.stdout) > 65536: raise ValueError('cb_first_ui/result')
    value = json.loads(child.stdout)
    armed = payload['armed']
    expected = dict(result='PASS' if armed else 'DRY_RUN', profile_removed=True, installed_bytes_match=True,
                    native_choice=True, writes=1 if armed else 0, denied=0 if armed else 1,
                    fresh_process=armed, credentials_not_persisted=True)
    if child.returncode or value != expected: raise ValueError('cb_first_ui/result')
    return True


def target_matches(raw, target, chapters, channel, summary):
    value = state(raw, target['book'], chapters, channel)
    return (value.get('kind') == 'located' and value.get('chapter_uid') == target['chapter']
            and value.get('chapter_idx') == target['index'] and value.get('chapter_offset') == target['first']
            and value.get('summary_present') is True and value.get('summary') == summary
            and type(value.get('raw_percent')) in (int, float) and 0 <= value['raw_percent'] <= 100)


def run(saved, session, native_store, grant, journal, intent, command, *, apply=False,
        upload_factory=UploadProbe, uploader=upload_run, ui_runner=run_ui, attest=ui_command):
    report = dict(result='UNVERIFIED', phase='preflight', position_writes_known=0,
                  position_writes_uncertain=False, account_data_writes_known=0, authentication_posts=0,
                  existing_book_writes=0, fixture_only=True, private_data_in_report=False)
    current = dict(saved=saved, sample=None, plan=None, source_hash=None, versions=None, shelf=None, completed=False)

    def same_grant(value): return native_store.load(current['saved']['vid']) == value

    def persist(web):
        if web.authenticated and save_refreshed_web_session(session, current['saved'], web):
            old = current['saved']; current['saved'] = session.load()
            if old['vid'] != current['saved']['vid']: raise ValueError('cb_first_ui/owner')
            old.clear()

    def connect(cls, target=None):
        web = cls(); web.vid = current['saved']['vid']
        if target is not None:
            web.book_id = target
            if hasattr(web, 'allowed'): web.allowed = {target}
        for key, value in current['saved']['cookies'].items(): web.set_cookie(key, value)
        web.verify_account(); return web

    def shelf(target=None):
        web = connect(WebSourceProbe)
        try:
            raw = web.request('shelf', WEB + '/web/shelf/sync')
            value = project(raw) if target is None else strip_fixture(raw, target)
            web.verify_account(); persist(web); return value
        finally: web.close()

    def source(target):
        web = connect(SourceRead, target)
        try:
            sample = web.inspect(target); web.verify_account()
            if (sample['book_id'] != target or sample['source_format'] != 'web_xhtml' or TEXT not in sample['source']
                    or set(web.last_checks) != {'catalog_unchanged', 'versions_unchanged', 'position_unchanged'}
                    or not all(web.last_checks.values())): return False
            current.update(sample=sample, plan=position_plan(target, sample), source_hash=sample['source_raw_sha256'],
                           versions=web.catalog_versions)
            persist(web); return True
        finally: web.samples.clear(); web.close()

    def trial(upload, receipt, _plan, target):
        sample, plan = current['sample'], current['plan']
        if not sample or not plan or shelf(target) != current['shelf']: return False
        owner = current['saved']['vid']
        if not owned(upload, receipt, target, owner, grant, same_grant): return False
        upload_state, _ = upload.read(); attempt = upload_state['attempt']; native = NativeRead(grant, target)
        def authority(): return owned(upload, receipt, target, owner, grant, same_grant)
        def pair():
            if not authority(): raise ValueError('cb_first_ui/owner')
            web = connect(WebSourceProbe, target)
            try:
                n = native.request('first_progress', NATIVE + '/book/getProgress?' + urlencode(dict(bookId=target)), credentials=grant)
                w = web.request('progress_after', WEB + '/web/book/getProgress?bookId=' + target)
                web.verify_account(); persist(web)
                return n, w
            finally: web.close()
        def baseline():
            raw = pair()
            value = {channel: observed(item, target, sample['chapters'], channel)
                     for channel, item in zip(('native', 'web'), raw)}
            if _classify(value, None, plan) != ['original', 'original']: raise ValueError('cb_first_ui/baseline')
            return value
        before = baseline()
        if baseline() != before: return False
        model = FilteredSource(sample['source'], allow_multiple_bodies=True)
        summary = ''.join(c for c in model.anchor_at(plan['first'], size=96) if not c.isspace())[:20]
        if not summary: return False
        bound = hashlib.sha256((current['source_hash'] + ':' + str(plan['first'])).encode()).hexdigest()
        reservation = intent.reserve(owner, target, attempt, bound)
        chapters = []
        for row in sample['chapters']:
            item = dict(row)
            if type(item.get('wordCount')) not in (int, float) or item['wordCount'] <= 0: item['wordCount'] = 1000
            chapters.append(item)
        payload = dict(book=target, chapter=plan['chapter'], chapter_idx=plan['index'], offset=plan['first'],
                       expected_summary=summary, source=sample['source'], chapters=chapters, book_version=0,
                       owner=owner, cookies=current['saved']['cookies'], native=grant, armed=False)
        if not authority() or attest() != command or not ui_runner(command, payload): return False
        report['native_dry_run_verified'] = True
        if baseline() != before or shelf(target) != current['shelf'] or not authority(): return False
        if attest() != command or baseline() != before or not authority(): return False
        permit = intent.claim(reservation, 'write_enter')
        if not intent.verify(reservation, permit) or not authority(): return False
        payload.update(cookies=current['saved']['cookies'], armed=True)
        report['position_writes_uncertain'] = True
        if not ui_runner(command, payload): return False
        report.update(position_writes_known=1, position_writes_uncertain=False, native_ui_confirmed=True)
        previous = None
        for _ in range(2):
            n, w = pair()
            if not target_matches(n, plan, sample['chapters'], 'native', summary) or not target_matches(w, plan, sample['chapters'], 'web', summary): return False
            if state(n, target, sample['chapters'], 'native')['raw_percent'] != state(w, target, sample['chapters'], 'web')['raw_percent']: return False
            projected = {channel: observed(item, target, sample['chapters'], channel)
                         for channel, item in (('native', n), ('web', w))}
            counts = projected['native']['counters']
            if any(not counts[k]['present'] or type(counts[k]['value']) is not int or counts[k]['value'] != 0
                   for k in ('readingTime', 'recordReadingTime', 'ttsTime')): return False
            if previous is not None and projected != previous: return False
            previous = projected
        again = connect(SourceRead, target)
        try:
            later = again.inspect(target); again.verify_account()
            valid = (later['source_raw_sha256'] == current['source_hash'] and later['chapter_uid'] == sample['chapter_uid']
                     and later['chapters'] == sample['chapters'] and again.catalog_versions == current['versions']
                     and set(again.last_checks) == {'catalog_unchanged', 'versions_unchanged', 'position_unchanged'}
                     and all(again.last_checks.values()))
            persist(again)
        finally: again.samples.clear(); again.close()
        current['completed'] = bool(valid and shelf(target) == current['shelf'] and authority() and intent.verify(reservation, permit))
        return current['completed']

    try:
        if journal.read()[0] is not None or intent.backend.load() is not None: raise ValueError('cb_first_ui/consumed')
        before = shelf()
        if shelf() != before: raise ValueError('cb_first_ui/shelf_changed')
        current['shelf'] = before
        upload = upload_factory(journal, same_grant)
        result = uploader(upload, journal, grant, same_grant, source, apply=apply, cleanup_gate=trial)
        report['upload'] = result; report['phase'] = result.get('phase', 'unknown')
        report['account_data_writes_known'] = (report['position_writes_known'] + result.get('cos_put_attempts', 0)
                                               + result.get('notify_posts', 0) + result.get('cleanup_posts', 0))
        if result.get('result') == 'READ_ONLY_PREVIEW': report['result'] = 'READ_ONLY_PREVIEW'
        elif result.get('result') == 'EPUB_IMPORT_AND_SOURCE_VERIFIED' and current['completed'] and shelf() == before:
            report.update(result='CB_FIRST_NATIVE_UI_VERIFIED', web_shelf_restored=True, independent_dual_readback=True)
    except Exception:
        report['result'] = 'UNVERIFIED'
    finally:
        current['sample'] = current['plan'] = None
        if current['saved'] is not saved and saved: saved.clear()
        if current['saved']: current['saved'].clear()
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true'); parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', account_data_writes_known=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = None
    try:
        command = ui_command(); session = SessionStore(); saved = session.load()
        native = NativeSessionStore(); grant = native.load(saved['vid'])
        report = run(saved, session, native, grant, *stores(), command, apply=args.apply)
    except Exception:
        report = dict(result='UNVERIFIED', position_writes_uncertain=False, account_data_writes_known=0)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report)); return int(report['result'] not in ('READ_ONLY_PREVIEW', 'CB_FIRST_NATIVE_UI_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
