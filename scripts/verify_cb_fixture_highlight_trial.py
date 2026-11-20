#!/usr/bin/env python3
"""One isolated self-authored CB highlight trial; offline by default.

Apply uses a fresh permanent upload journal and a separate two-write intent.
Only that verified new fixture may be changed. Each write is independently
read back; an exception or unexpected state prevents retries and cleanup.
Credentials, source, identifiers and raw account responses are not reported.
"""
import argparse
import json
from pathlib import Path
import resource
import tempfile
import time
from urllib.parse import urlencode

from annotation_experiment_model import digest, marks_state, shelf_state, thoughts_state
from cb_fixture_highlight_trial import Intent, execute, prepare
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_fixture_position_trial import owned
from verify_cb_progress import cb_id
from verify_cb_reading import CbReadingError, CbReadingProbe
from verify_cb_metadata import CbMetadataError
from verify_eink_login import BASE, NativeProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_reader_progress import project as progress_project
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session

UPLOAD_SERVICE = 'org.codex.weread.cb-fixture-highlight-upload-v1'


def make_journal():
    backend = MacKeychain(service=UPLOAD_SERVICE, account=ACCOUNT)
    path = Path(tempfile.gettempdir()) / ('codex-cb-fixture-highlight-upload-' + ACCOUNT + '.lock')
    return Journal(backend=backend, lock=lambda: project_lock(path))


class ScopedNative(NativeProbe):
    MAX_GETS = 200
    def __init__(self, book, grant, authority, intent, *, opener=None, max_gets=40):
        if not cb_id(book) or type(max_gets) is not int or not 1 <= max_gets <= self.MAX_GETS: raise ValueError('cb_highlight/scope')
        super().__init__(opener)
        self.book, self.grant_hash, self.authority, self.intent = book, digest(grant), authority, intent
        self.posts, self.gets, self.body, self.pending, self.max_gets = 0, 0, None, None, max_gets

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        if not self.authority() or digest(credentials) != self.grant_hash:
            raise ValueError('cb_highlight/ownership')
        queries = {'shelf': BASE + '/shelf/sync',
                   'marks': BASE + '/book/bookmarklist?' + urlencode(dict(bookId=self.book, synckey=0)),
                   'thoughts': BASE + '/review/list?' + urlencode(dict(bookId=self.book, listType=11, listMode=0, mine=1, synckey=0, count=20)),
                   'position': BASE + '/book/getProgress?' + urlencode(dict(bookId=self.book)),
                   'info': BASE + '/book/info?' + urlencode(dict(bookId=self.book))}
        if body is None:
            if queries.get(stage) != url or self.gets >= self.max_gets: raise ValueError('cb_highlight/read_scope')
            self.gets += 1
        else:
            state, receipt = self.intent.read()
            if (self.pending is None or state is None or receipt != self.pending[1] or stage != self.pending[0]
                    or not self.intent.owns(receipt, stage) or self.posts != (0 if stage == 'create_pending' else 1)
                    or state['plan']['book_sha256'] != digest(self.book)
                    or state['plan']['owner_sha256'] != digest(credentials['vid'])):
                raise ValueError('cb_highlight/write_scope')
            if stage == 'create_pending':
                if (url != BASE + '/book/addBookmark' or body != self.body or body.get('bookId') != self.book
                        or digest(body) != state['plan']['request_sha256']):
                    raise ValueError('cb_highlight/write_scope')
            elif stage == 'delete_pending':
                if url != BASE + '/book/removeBookmark' or body != {'bookmarkIds': [state['target']['id']]}:
                    raise ValueError('cb_highlight/write_scope')
            else: raise ValueError('cb_highlight/write_scope')
            self.posts += 1
        result = super().request(stage, url, body, credentials, timeout)
        if not self.authority(): raise ValueError('cb_highlight/ownership')
        return result

    def get(self, stage, grant):
        paths = {'shelf': '/shelf/sync',
                 'marks': '/book/bookmarklist?' + urlencode(dict(bookId=self.book, synckey=0)),
                 'thoughts': '/review/list?' + urlencode(dict(bookId=self.book, listType=11, listMode=0, mine=1, synckey=0, count=20)),
                 'position': '/book/getProgress?' + urlencode(dict(bookId=self.book)),
                 'info': '/book/info?' + urlencode(dict(bookId=self.book))}
        return self.request(stage, BASE + paths[stage], credentials=grant)

    def observe(self, grant):
        position = progress_project(self.get('position', grant), self.book, source='native')
        return dict(shelf=shelf_state(self.get('shelf', grant)), position=position,
                    thoughts=thoughts_state(self.get('thoughts', grant), self.book, grant['vid']),
                    marks=marks_state(self.get('marks', grant), self.book, grant['vid']))

    def version(self, grant):
        info = self.get('info', grant)
        value = info.get('bookVersion', info.get('version'))
        if str(info.get('bookId')) != self.book or type(value) is not int or not 0 <= value <= 2147483647:
            raise ValueError('cb_highlight/version')
        return value

    def send(self, stage, body, receipt, grant):
        if self.pending is not None: raise ValueError('cb_highlight/write_scope')
        self.pending = (stage, receipt)
        try:
            path = '/book/addBookmark' if stage == 'create_pending' else '/book/removeBookmark'
            return self.request(stage, BASE + path, body, grant)
        finally:
            self.pending = None


def run(saved, session, native_store, grant, journal, intent, *, apply=False,
        uploader=upload_run, upload_factory=UploadProbe, native_factory=ScopedNative, source_factory=CbReadingProbe,
        prepare_fn=prepare, execute_fn=execute, final_check=None, result_label='CB_FIXTURE_HIGHLIGHT_VERIFIED', expected_posts=2,
        source_sleep=time.sleep, source_format='web_xhtml', source_marker=TEXT,
        upload_success='EPUB_IMPORT_AND_SOURCE_VERIFIED', fixture_authorized=owned):
    report = dict(result='UNVERIFIED', phase='preflight', annotation_posts=0, authentication_posts=0,
                  existing_book_writes=0, fixture_only=True, private_values_in_report=False)
    current = {'saved': saved, 'sample': None, 'native': None, 'trial': None}
    def same_grant(value): return native_store.load(current['saved']['vid']) == value
    def source(target):
        current['sample']=None
        for attempt in range(3):
            web = source_factory(); web.vid = current['saved']['vid']; web.allowed = {target}
            try:
                for key, value in current['saved']['cookies'].items(): web.set_cookie(key, value)
                web.verify_account(); sample = web.inspect(target); web.verify_account()
                if (sample.get('book_id') != target or sample.get('source_format') != source_format
                        or source_marker not in sample.get('source', '') or set(web.last_checks) != {'catalog_unchanged', 'versions_unchanged', 'position_unchanged'}
                        or not all(value is True for value in web.last_checks.values())):
                    report['source_failure']='invalid_sample'; return False
                if save_refreshed_web_session(session, current['saved'], web):
                    old = current['saved']; current['saved'] = session.load()
                    if old['vid'] != current['saved']['vid']: raise ValueError('cb_highlight/owner')
                    old.clear()
                report.pop('source_failure',None)
                current['sample'] = sample
                return True
            except (CbReadingError, CbMetadataError) as error:
                known={'cb_catalog_empty','cb_catalog_invalid','cb_catalog_identity','cb_resume_chapter_missing',
                       'cb_reader_chapter_mismatch','cb_txt_marker_invalid','cb_source_invalid','cb_read_baseline_changed',
                       'cb_source_anchor_unavailable','cb_content_scope','cb_read_scope','cb_read_repeated'}
                report['source_failure']=str(error) if str(error) in known else 'other'
                if str(error) not in ('cb_catalog_empty', 'cb_catalog_invalid') or attempt == 2: raise
            except Exception:
                report['source_failure']='other'; raise
            finally:
                web.samples.clear(); web.close()
            source_sleep(2 * (attempt + 1))
        return False

    def trial(upload, receipt, _plan, target):
        owner = current['saved']['vid']; sample = current['sample']
        def authority(): return bool(cb_id(target) and fixture_authorized(upload, receipt, target, owner, grant, same_grant))
        if not authority(): return False
        if sample is None: return True  # No annotation was sent; exact upload cleanup remains separately guarded.
        state, _ = upload.read(); native = native_factory(target, grant, authority, intent); current['native'] = native
        try:
            before = native.observe(grant); version = native.version(grant)
            if native.version(grant) != version: raise ValueError('cb_highlight/version_changed')
            plan, body = prepare_fn(owner, target, state['attempt'], sample, version, before)
            native.body = body
            current['trial'] = execute_fn(plan, body, before, intent, authority,
                                       lambda: native.observe(grant), lambda stage, value, permit: native.send(stage, value, permit, grant))
            after_marks=native.observe(grant)
            if native.posts != expected_posts or not (final_check(before,after_marks,body) if final_check else after_marks==before): return False
            old = sample; current['sample'] = None
            if not source(target): return False
            after = current['sample']
            return bool(authority() and after['source_raw_sha256'] == old['source_raw_sha256']
                        and after['chapter_uid'] == old['chapter_uid'] and after['chapters'] == old['chapters']
                        and after['baseline'] == old['baseline'])
        except Exception:
            # An unattempted trial may remove the fixture; an uncertain write never can.
            return bool(native.posts == 0 and intent.read()[0] is None and authority())
        finally:
            report['annotation_posts'] = native.posts

    try:
        if journal.read()[0] is not None or intent.read()[0] is not None: raise ValueError('cb_highlight/consumed')
        upload = upload_factory(journal, same_grant)
        result = uploader(upload, journal, grant, same_grant, source, apply=apply, cleanup_gate=trial)
        report['upload'] = result; report['phase'] = result.get('phase', 'unknown')
        if result.get('result') == 'READ_ONLY_PREVIEW': report['result'] = 'READ_ONLY_PREVIEW'
        elif result.get('result') == upload_success and current['trial'] and current['trial']['result'] == 'PASS':
            report.update(result=result_label, original_records_restored=True,
                          fixture_removed=True, no_replay=True)
    except Exception:
        report['result'] = 'UNVERIFIED'
    finally:
        current['sample'] = None
        if current['saved'] is not saved and saved: saved.clear()
        if current['saved']: current['saved'].clear()
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true'); parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', annotation_posts=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = None
    try:
        session = SessionStore(); saved = session.load(); native = NativeSessionStore(); grant = native.load(saved['vid'])
        report = run(saved, session, native, grant, make_journal(), Intent(), apply=args.apply)
    except Exception:
        report = dict(result='UNVERIFIED', phase='setup', annotation_posts=0)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report, ensure_ascii=False)); return 0 if report['result'] in ('READ_ONLY_PREVIEW', 'CB_FIXTURE_HIGHLIGHT_VERIFIED') else 1


if __name__ == '__main__': raise SystemExit(main())
