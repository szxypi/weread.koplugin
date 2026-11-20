#!/usr/bin/env python3
"""Verify first CB position using only a newly uploaded synthetic EPUB.

Offline by default. A permanent, separate upload journal and two claimed
position slots prevent replay. Unknown effects keep the exact fixture in place.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import tempfile
from urllib.parse import urlencode

from cb_cloud_position import observed
from cb_fixture_position import plan as position_plan
from cb_initial_fixture_flow import run as position_run
from cb_initial_fixture_intent import Intent
from cb_initial_fixture_transport import ScopedProbe
from cloud_group_contract import project
from cloud_group_nonempty_workflow import strip_fixture
from fetch_weread_epub import normalize_chapter_infos
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_fixture_position_trial import owned
from verify_cb_reading import CbReadingProbe
from verify_eink_login import BASE as NATIVE, NativeProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_position_roundtrip import canonical
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB, WebSourceProbe, versions

UPLOAD_SERVICE = 'org.codex.weread.cb-first-fixture-upload-v1'


def upload_journal():
    backend = MacKeychain(service=UPLOAD_SERVICE, account=ACCOUNT)
    path = Path(tempfile.gettempdir()) / ('codex-cb-first-fixture-upload-' + ACCOUNT + '.lock')
    return Journal(backend=backend, lock=lambda: project_lock(path))


class NativeRead(NativeProbe):
    def __init__(self, grant, target):
        super().__init__(); self.grant, self.target, self.reads = grant, target, 0

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        if (stage != 'first_progress' or body is not None or credentials != self.grant
                or url != NATIVE + '/book/getProgress?' + urlencode(dict(bookId=self.target)) or self.reads >= 40):
            raise ValueError('cb_first/native_scope')
        self.reads += 1
        return super().request(stage, url, credentials=credentials, timeout=timeout)


class SourceRead(CbReadingProbe):
    def __init__(self):
        super().__init__(); self.catalog_versions = None

    def request(self, stage, url, body=None, **kwargs):
        result = super().request(stage, url, body, **kwargs)
        if stage == 'catalog_before':
            record, _ = normalize_chapter_infos(result, self.book_id)
            self.catalog_versions = versions(record)
        return result


def run(saved, session, native_store, grant, journal, intent, *, apply=False,
        upload_factory=UploadProbe, uploader=upload_run, sleeper=None,
        source_format='web_xhtml', source_marker=TEXT, position_planner=position_plan,
        upload_success='EPUB_IMPORT_AND_SOURCE_VERIFIED', fixture_authorized=None):
    import time
    sleep = sleeper or time.sleep
    report = dict(result='UNVERIFIED', phase='preflight', position_writes=0,
                  account_data_writes_known=0, authentication_posts=0, fixture_only=True,
                  existing_book_writes=0, private_data_in_report=False)
    current = dict(saved=saved, sample=None, target_plan=None, source_hash=None, source_versions=None, position=None, web_shelf=None)

    def same_grant(value): return native_store.load(current['saved']['vid']) == value

    def persist(web):
        if web.authenticated and save_refreshed_web_session(session, current['saved'], web):
            old = current['saved']; current['saved'] = session.load()
            if old['vid'] != current['saved']['vid']: raise ValueError('cb_first/owner')
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
            if (sample['book_id'] != target or sample['source_format'] != source_format or source_marker not in sample['source']
                    or set(web.last_checks) != {'catalog_unchanged', 'versions_unchanged', 'position_unchanged'}
                    or not all(web.last_checks.values())): return False
            current['sample'] = sample
            current['source_hash'] = sample['source_raw_sha256']
            current['source_versions'] = web.catalog_versions
            current['target_plan'] = position_planner(target, sample)
            persist(web); return True
        finally: web.samples.clear(); web.close()

    def trial(upload, receipt, _plan, target):
        if not current['sample'] or not current['target_plan'] or shelf(target) != current['web_shelf']:
            return False
        owner = current['saved']['vid']
        def owned_fixture():
            return (owned(upload, receipt, target, owner, grant, same_grant)
                    and (fixture_authorized is None or fixture_authorized(upload, receipt, target, owner)))
        if not owned_fixture(): return False
        state, _ = upload.read(); attempt = state['attempt']; sample = current['sample']; plan = current['target_plan']
        bound = hashlib.sha256((current['source_hash'] + ':' + str(plan['first'])).encode()).hexdigest()
        reservation = intent.reserve(owner, target, attempt, bound)
        initial_receipt = canonical(reservation).encode()
        def authority(value=None):
            return (owned_fixture()
                    and intent.verify(reservation, initial_receipt if value is None else value))
        def claim(stage): return intent.claim(reservation, stage)
        native = NativeRead(grant, target)
        web = ScopedProbe(plan, owner, lambda: authority(web.permit), intent, reservation)
        try:
            for key, value in current['saved']['cookies'].items(): web.set_cookie(key, value)
            web.verify_account()
            def read_pair():
                if not owned_fixture(): raise ValueError('cb_first/owner')
                n = native.request('first_progress', NATIVE + '/book/getProgress?' + urlencode(dict(bookId=target)), credentials=grant)
                w = web.request('progress_after', WEB + '/web/book/getProgress?bookId=' + target)
                return {channel: observed(raw, target, sample['chapters'], channel)
                        for channel, raw in (('native', n), ('web', w))}
            current['position'] = position_run(plan, read_pair, claim, authority, web.send_claimed, sleep=sleep)
            report['position_writes'] = current['position']['writes']
            if current['position']['result'] != 'PASS': return False
            persist(web)
        finally:
            if web.authenticated: persist(web)
            web.close()
        # Re-read the same source and catalog, and check all pre-existing Web
        # shelf state, before allowing the upload routine to remove the fixture.
        again = connect(SourceRead, target)
        try:
            later = again.inspect(target); again.verify_account()
            valid = (later['source_raw_sha256'] == current['source_hash'] and later['chapter_uid'] == sample['chapter_uid']
                     and later['chapters'] == sample['chapters']
                     and again.catalog_versions == current['source_versions']
                     and set(again.last_checks) == {'catalog_unchanged', 'versions_unchanged', 'position_unchanged'}
                     and all(again.last_checks.values()))
            persist(again)
        finally: again.samples.clear(); again.close()
        return bool(valid and shelf(target) == current['web_shelf'] and authority(canonical(reservation).encode()))

    try:
        if journal.read()[0] is not None or intent.backend.load() is not None: raise ValueError('cb_first/consumed')
        before = shelf(); after = shelf()
        if before != after: raise ValueError('cb_first/shelf_changed')
        current['web_shelf'] = before
        upload = upload_factory(journal, same_grant)
        result = uploader(upload, journal, grant, same_grant, source, apply=apply, cleanup_gate=trial)
        report['upload'] = result; report['phase'] = result.get('phase', 'unknown')
        report['account_data_writes_known'] = (report['position_writes'] + result.get('cos_put_attempts', 0)
                                               + result.get('notify_posts', 0) + result.get('cleanup_posts', 0))
        if result.get('result') == 'READ_ONLY_PREVIEW': report['result'] = 'READ_ONLY_PREVIEW'
        elif (result.get('result') == upload_success and current['position']
              and current['position']['result'] == 'PASS' and shelf() == before):
            report.update(result='CB_INITIAL_FIXTURE_VERIFIED', position=current['position'], web_shelf_restored=True)
    except Exception:
        report['result'] = 'UNVERIFIED'
    finally:
        current['sample'] = current['target_plan'] = None
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
        session = SessionStore(); saved = session.load(); native = NativeSessionStore(); grant = native.load(saved['vid'])
        report = run(saved, session, native, grant, upload_journal(), Intent(), apply=args.apply)
    except Exception:
        report = dict(result='UNVERIFIED', account_data_writes_known=0)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report)); return int(report['result'] not in ('READ_ONLY_PREVIEW', 'CB_INITIAL_FIXTURE_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
