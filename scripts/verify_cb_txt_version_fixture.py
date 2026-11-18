#!/usr/bin/env python3
"""Inspect versions on one newly imported self-authored TXT, then remove it.

Offline by default. The import and cleanup use a fresh one-shot journal; this
tool never sends reading position or time. Only bounded version categories and
counts are reported, and an ambiguous write is not replayed.
"""
import argparse
import json
from pathlib import Path
import resource
import tempfile
from urllib.parse import urlencode

from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_cb_metadata import CbNativeMetadataProbe
from verify_cb_reading import CbReadingProbe, readable_chapters
from verify_cb_txt_fixture import Journal, MARKER, Receipt, execute, guarded_previous
from verify_eink_login import BASE, NativeProbe
from verify_personal_upload_trial import Probe
from verify_shelf_flags import WebFlagsProbe


def stores():
    def backend(name): return MacKeychain(service='org.codex.weread.cb-txt-version-fixture-' + name + '-v1', account=ACCOUNT)
    path = Path(tempfile.gettempdir()) / ('codex-cb-txt-version-fixture-upload-' + ACCOUNT + '.lock')
    return Journal(backend=backend('upload'), lock=lambda: project_lock(path)), Receipt(backend=backend('receipt'))


def fields(node):
    if not isinstance(node, dict): raise ValueError('txt_version/node')
    return [(key, node[key]) for key in ('bookVersion', 'version') if key in node]


def category(values):
    if not values: return 'absent'
    numbers = [value for _key, value in values]
    if any(type(value) is not int or value < 0 or value > 2147483647 for value in numbers): return 'invalid'
    if any(value != numbers[0] for value in numbers): return 'conflicting'
    return 'zero' if numbers[0] == 0 else 'positive'


class CatalogProbe(CbReadingProbe):
    def __init__(self): super().__init__(); self.version_fields = {}
    def request(self, stage, url, body=None, **kwargs):
        value = super().request(stage, url, body, **kwargs)
        if stage in ('catalog_before', 'catalog_after'):
            record, _chapters = readable_chapters(value, self.book_id)
            self.version_fields[stage] = (fields(record), fields(record.get('book', {})))
        return value


def inspect_fixture(saved, grant, target, current, summary, *, web_factory=CatalogProbe, native_factory=CbNativeMetadataProbe):
    if current(grant) is not True: raise ValueError('txt_version/session')
    web = web_factory(); web.vid = saved['vid']; web.allowed = {target}
    try:
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        web.verify_account(); sample = web.inspect(target); web.verify_account()
        if (sample['book_id'] != target or sample['source_format'] != 'web_txt' or MARKER not in sample['source']
                or set(web.last_checks) != {'catalog_unchanged', 'versions_unchanged', 'position_unchanged'}
                or not all(value is True for value in web.last_checks.values())): return False
        before, after = web.version_fields.get('catalog_before'), web.version_fields.get('catalog_after')
        if before is None or before != after: return False
        native_values = []
        for _index in range(2):
            if current(grant) is not True: return False
            native = native_factory(); native.allowed_ids = {target}
            value = native.request('metadata', BASE + '/book/info?' + urlencode({'bookId': target}), credentials=grant)
            if not isinstance(value, dict) or value.get('bookId') != target: return False
            native_values.append(fields(value))
        if native_values[0] != native_values[1] or current(grant) is not True: return False
        root, nested = before; native_fields = native_values[0]; all_web = root + nested
        summary.update(source_format='web_txt', web_catalog_stable=True, native_metadata_stable=True,
                       native_version_category=category(native_fields), catalog_root_version_category=category(root),
                       catalog_book_version_category=category(nested),
                       web_and_native_positive_match=bool(native_fields and all_web and category(native_fields)=='positive'
                           and category(all_web)=='positive' and native_fields[0][1]==all_web[0][1]))
        return True
    finally:
        web.samples.clear(); web.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true'); parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('--apply requires --saved-session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', account_data_writes=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = web = None; summary = {}; result = None
    try:
        session = SessionStore(); saved = session.load(); native_store = NativeSessionStore(); grant = native_store.load(saved['vid'])
        def current(value=None): return session.load()==saved and native_store.load(saved['vid'])==grant and (value is None or value==grant)
        web = WebFlagsProbe(); web.vid = saved['vid']
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        native = NativeProbe(); web.verify_account()
        previous = lambda: guarded_previous(grant, current, native, web)
        journal, receipt = stores()
        result = execute(Probe(journal, current), journal, receipt, grant, current,
                         lambda target: inspect_fixture(saved, grant, target, current, summary), previous, apply=args.apply)
        result.update(summary); result['old_group_guard_passed_after'] = previous()
        result['account_data_writes'] = result['notify_posts'] + result['cleanup_posts']
        result['existing_book_writes'] = 0; result['private_data_in_report'] = False
    except Exception:
        result = dict(result='UNVERIFIED', phase='unknown' if args.apply else 'preflight',
                      account_data_writes=None if args.apply else 0, authentication_posts=0,
                      existing_book_writes=0, private_data_in_report=False)
    finally:
        if web: web.close()
        if grant: grant.clear()
        if saved: saved.clear()
    print(json.dumps(result)); return int(result['result'] not in ('READ_ONLY_PREVIEW','TXT_IMPORT_AND_SOURCE_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
