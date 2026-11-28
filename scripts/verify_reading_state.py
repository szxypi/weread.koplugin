#!/usr/bin/env python3
"""Read-only, bounded observation of the server's start-reading field.

Default is offline. The opt-in owner sample reports aggregates only, never
book IDs, titles, positions or credentials. It cannot send account writes.
"""
import argparse
from collections import Counter
import json
import re
import resource
from urllib.parse import urlencode

from cloud_group_contract import project
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE, NativeProbe
from verify_web_source_progress import WebSourceProbe


def bit(value):
    return str(value) if type(value) is int and value in (0, 1) else 'unknown'


def zero_or_nonzero(value):
    if type(value) not in (int, float) or value < 0 or value != value or value == float('inf'):
        return 'unknown'
    return 'zero' if value == 0 else 'nonzero'


def observation(data, identity, finished):
    if not isinstance(data, dict) or not isinstance(data.get('book'), dict):
        raise ValueError('reading_state/progress')
    book = data['book']
    for node in (data, book):
        if 'bookId' in node and str(node['bookId']) != identity:
            raise ValueError('reading_state/identity')
    return 'started={};chapter={};time={};finished={}'.format(
        bit(book.get('isStartReading')), zero_or_nonzero(book.get('chapterUid')),
        zero_or_nonzero(book.get('startReadingTime')), bit(finished))


class ReadOnlyProbe(NativeProbe):
    def __init__(self, opener=None):
        super().__init__(opener)
        self.allowed = set()
        self.used = set()
        self.shelf_reads = 0

    def shelf(self, credentials):
        if self.shelf_reads >= 2:
            raise ValueError('reading_state/scope')
        self.shelf_reads += 1
        return super().request('shelf', BASE + '/shelf/sync', credentials=credentials)

    def progress(self, credentials, identity):
        if identity not in self.allowed or identity in self.used:
            raise ValueError('reading_state/scope')
        self.used.add(identity)
        return super().request('progress', BASE + '/book/getProgress?' + urlencode({'bookId': identity}),
                               credentials=credentials)

    def request(self, *args, **kwargs):
        raise ValueError('reading_state/scope')


def inspect(probe, credentials, sample=30):
    if type(sample) is not int or not 1 <= sample <= 30:
        raise ValueError('reading_state/sample')
    shelf = probe.shelf(credentials)
    before = project(shelf)
    rows = []
    for row in shelf['books']:
        identity = str(row.get('bookId', ''))
        if re.fullmatch(r'[1-9][0-9]{0,19}', identity):
            rows.append((identity, row.get('finishReading')))
    rows.sort(key=lambda row: row[0])
    rows = rows[:sample]
    if not rows:
        raise ValueError('reading_state/empty')
    probe.allowed = {identity for identity, _ in rows}
    counts = Counter(observation(probe.progress(credentials, identity), identity, finished)
                     for identity, finished in rows)
    after = project(probe.shelf(credentials))
    if before != after:
        raise ValueError('reading_state/shelf_changed')
    return dict(result='READ_ONLY_OBSERVED', sampled=len(rows), combinations=dict(sorted(counts.items())),
                shelf_unchanged=True, account_writes_attempted=0)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    args = parser.parse_args(argv)
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', account_writes_attempted=0)))
        return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = credentials = web = None
    try:
        saved = SessionStore().load()
        credentials = NativeSessionStore().load(saved['vid'])
        web = WebSourceProbe()
        web.vid = saved['vid']
        for key, value in saved['cookies'].items():
            web.set_cookie(key, value)
        web.verify_account()
        report = inspect(ReadOnlyProbe(), credentials)
    except Exception:
        report = dict(result='UNVERIFIED', account_writes_attempted=0)
    finally:
        if web:
            web.close()
        if saved:
            saved.clear()
        if credentials:
            credentials.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] == 'READ_ONLY_OBSERVED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
