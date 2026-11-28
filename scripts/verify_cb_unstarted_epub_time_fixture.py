#!/usr/bin/env python3
"""Verify time on one new, self-authored EPUB before its first position."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import resource
import tempfile
import time
from urllib.parse import urlencode

from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from cb_native_readtime_model import batch
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_metadata import CbMetadataError, CbNativeMetadataProbe
from verify_cb_reading import CbReadingError
from verify_cb_txt_fixture import Receipt
from verify_cb_txt_version_fixture import CatalogProbe, category, fields
from verify_cb_txt_zero_native_batch import ZeroBatchProbe
from verify_eink_login import BASE


def stores():
    def backend(name): return MacKeychain(service='org.codex.weread.cb-unstarted-epub-time-' + name + '-v1', account=ACCOUNT)
    def lock(name):
        path = Path(tempfile.gettempdir()) / ('codex-cb-unstarted-epub-time-' + name + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return (Journal(backend=backend('upload'), lock=lock('upload')), Receipt(backend=backend('receipt')),
            Intent(backend=backend('time'), lock=lock('time')), Evidence(backend=backend('baseline'), lock=lock('baseline')))


def inspect_once(saved, grant, target, current, summary, *, expected_source=None,
                 web_factory=CatalogProbe, native_factory=CbNativeMetadataProbe):
    if current(grant) is not True: raise ValueError('epub_version/session')
    web = web_factory(); web.vid = saved['vid']; web.allowed = {target}
    try:
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        web.verify_account(); sample = web.inspect(target); web.verify_account()
        if (sample['book_id'] != target or sample['source_format'] != 'web_xhtml' or TEXT not in sample['source']
                or expected_source is not None and sample.get('source_raw_sha256') != expected_source
                or set(web.last_checks) != {'catalog_unchanged', 'versions_unchanged', 'position_unchanged'}
                or not all(value is True for value in web.last_checks.values())): return False
        before, after = web.version_fields.get('catalog_before'), web.version_fields.get('catalog_after')
        if before is None or before != after: return False
        values = []
        for _ in range(2):
            if current(grant) is not True: return False
            native = native_factory(); native.allowed_ids = {target}
            value = native.request('metadata', BASE + '/book/info?' + urlencode({'bookId': target}), credentials=grant)
            if not isinstance(value, dict) or value.get('bookId') != target: return False
            values.append(fields(value))
        if values[0] != values[1] or current(grant) is not True: return False
        root, nested = before; native_fields = values[0]; web_fields = root + nested
        if (category(native_fields) != 'positive' or category(web_fields) != 'positive'
                or native_fields[0][1] != web_fields[0][1]): return False
        summary.update(version=native_fields[0][1], web_and_native_positive_match=True)
        return True
    finally:
        web.samples.clear(); web.close()


def inspect_epub(saved, grant, target, current, summary, *, expected_source=None, sleep=time.sleep):
    for attempt in range(5):
        try: return inspect_once(saved, grant, target, current, summary, expected_source=expected_source)
        except (CbReadingError, CbMetadataError) as error:
            if str(error) not in ('cb_catalog_empty', 'cb_catalog_invalid') or attempt == 4: raise
        sleep(2 * (attempt + 1))
    return False


def positive_batch(grant, target, start, now, guest, config, version, random1, random2, zone):
    if type(version) is not int or version <= 0: raise ValueError('epub_version/invalid')
    rows = [dict(start_time=start, duration=2, time_zone=zone, book_version=version)]
    return batch(grant, target, rows, guest, config, now, random1, now * 1000, random2, current_zone=zone)


class EpubBatchProbe(ZeroBatchProbe):
    version = None
    def bind(self, value, summary):
        if (self.expected is not None or not self.authority() or not isinstance(value, dict)
                or len(value.get('books', [])) != 1): raise ValueError('epub_time/scope')
        book = value['books'][0]
        if (book.get('bookId') != self.book or type(self.version) is not int or self.version <= 0
                or book.get('bookVersion') != self.version or book.get('summary') != summary
                or book.get('readingTime') != 2 or book.get('isResendReadingInfo') != 1
                or sum(hour.get('readingTime', 0) for hour in book.get('hours', [])) != 2):
            raise ValueError('epub_time/body')
        self.expected = deepcopy(value)


def main(argv=None):
    from verify_cb_unstarted_time_fixture import run
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true'); parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', account_data_writes_known=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = None
    try:
        session = SessionStore(); saved = session.load(); native = NativeSessionStore(); grant = native.load(saved['vid'])
        report = run(saved, session, native, grant, *stores(), apply=args.apply, fixture='epub')
    except Exception:
        report = dict(result='UNVERIFIED', phase='unknown' if args.apply else 'preflight',
                      account_data_writes_known=None if args.apply else 0, authentication_posts=0,
                      existing_book_writes=0, fixture_only=True, private_data_in_report=False)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report))
    return int(report['result'] not in ('READ_ONLY_PREVIEW', 'UNSTARTED_TIME_FIXTURE_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
