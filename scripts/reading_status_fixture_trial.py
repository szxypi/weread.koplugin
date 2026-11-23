"""Fail-closed status=2 trial for exactly one independently bound EPUB fixture.

This module has no executable entry point. The caller supplies separately
scoped read and send functions. A dispatched phase is permanently consumed.
"""
from copy import deepcopy

from cloud_group_fixture import binding
from cloud_group_nonempty_workflow import strip_fixture
from personal_upload_trial import hash_value
from verify_cb_progress import cb_id
from verify_finish_roundtrip import acknowledged


FIELDS = ('chapterUid', 'chapterIdx', 'chapterOffset', 'progress')
COUNTERS = ('readingTime', 'recordReadingTime', 'ttsTime')
OBSERVABLE = ('isStartReading', 'startReadingTime', 'reading', 'readStatus', 'readingStatus',
              'status', 'markStatus', 'finishReading', 'readUpdateTime')


def select(value, names):
    if not isinstance(value, dict):
        raise ValueError('reading_trial/invalid')
    return {key: deepcopy(value[key]) for key in names if key in value}


def progress(raw, target):
    if not isinstance(raw, dict) or not isinstance(raw.get('book'), dict):
        raise ValueError('reading_trial/progress')
    book = raw['book']
    for node in (raw, book):
        if 'bookId' in node and str(node['bookId']) != target:
            raise ValueError('reading_trial/identity')
    flag = book.get('isStartReading')
    if type(flag) is not int or flag not in (0, 1):
        raise ValueError('reading_trial/flag')
    return dict(flag=flag, position=select(book, FIELDS), counters=select(raw, COUNTERS),
                observed=select(book, OBSERVABLE))


def target_row(shelf, target):
    rows = shelf.get('books') if isinstance(shelf, dict) else None
    if not isinstance(rows, list):
        raise ValueError('reading_trial/shelf')
    matches = [row for row in rows if isinstance(row, dict) and str(row.get('bookId')) == target]
    if len(matches) != 1:
        raise ValueError('reading_trial/target')
    return select(matches[0], OBSERVABLE + ('secret', 'isTop', 'finished'))


def request(target, cancel):
    if not cb_id(target) or type(cancel) is not bool:
        raise ValueError('reading_trial/request')
    return dict(auto=0, bookId=target, finishInfo=0, isCancel=int(cancel), status=2)


class Trial:
    def __init__(self, upload, receipt, grant, current, pending, original, read, send):
        self.upload, self.receipt, self.grant = upload, receipt, grant
        self.current, self.pending, self.original, self.read, self.send = current, pending, original, read, send
        self.report = dict(result='UNVERIFIED', phase='preflight', status_posts=0,
                           mark_acknowledged=False, restore_acknowledged=False,
                           changed_native_fields=[], changed_shelf_fields=[])

    def bound(self, target):
        if self.current() is not True or self.pending() is not True:
            raise ValueError('reading_trial/owner')
        state, _ = binding(self.upload, self.receipt.backend)
        if (state['target'] != target or state['plan']['owner'] != self.grant['vid']
                or state['plan']['grant_sha256'] != hash_value(self.grant)):
            raise ValueError('reading_trial/binding')
        return state

    def snapshot(self, target):
        self.bound(target)
        value = self.read(target)
        if not isinstance(value, dict) or set(value) != {'native_shelf', 'web_shelf', 'native_progress'}:
            raise ValueError('reading_trial/read')
        for channel in ('native', 'web'):
            if strip_fixture(value[channel + '_shelf'], target) != self.original[channel]:
                raise ValueError('reading_trial/unrelated')
        result = dict(native=target_row(value['native_shelf'], target),
                      web=target_row(value['web_shelf'], target),
                      progress=progress(value['native_progress'], target))
        self.bound(target)
        return result

    def run(self, target):
        try:
            state = self.bound(target)
            before = self.snapshot(target)
            position = before['progress']['position']
            chapter = position.get('chapterUid')
            if (before != self.snapshot(target) or before['progress']['flag'] != 0
                    or type(chapter) is not int or chapter != 0
                    or any(type(position[key]) not in (int, float) or position[key] != 0
                           for key in ('chapterOffset', 'progress') if key in position)
                    or any('finishReading' in before[channel]
                           and (type(before[channel]['finishReading']) is not int
                                or before[channel]['finishReading'] != 0)
                           for channel in ('native', 'web'))):
                raise ValueError('reading_trial/baseline')
            self.report['phase'] = 'mark_pending'
            body = request(target, False)
            plan = dict(selection=dict(owner=self.grant['vid'], target=target, upload_attempt=state['attempt'],
                                       upload_plan_hash=hash_value(state['plan']), grant_hash=hash_value(self.grant)),
                        record=dict(kind='mark'), body=body, baseline=dict(snapshot_hash=hash_value(before)))
            # send must persist its one-shot intent before any network dispatch.
            self.report['status_posts'] += 1
            response = self.send('mark', plan)
            self.report['mark_acknowledged'] = acknowledged(response)
            after = self.snapshot(target)
            if after != self.snapshot(target):
                raise ValueError('reading_trial/unstable')
            self.report['changed_native_fields'] = [key for key in OBSERVABLE
                if before['progress']['observed'].get(key, object()) != after['progress']['observed'].get(key, object())
                and (key in before['progress']['observed'] or key in after['progress']['observed'])]
            self.report['changed_shelf_fields'] = [key for key in OBSERVABLE
                if before['native'].get(key, object()) != after['native'].get(key, object())
                and (key in before['native'] or key in after['native'])]
            if (not self.report['mark_acknowledged'] or after['progress']['flag'] != 1
                    or after['progress']['position'] != before['progress']['position']
                    or after['progress']['counters'] != before['progress']['counters']
                    or any(select(after[channel], ('secret', 'isTop', 'finished', 'finishReading'))
                           != select(before[channel], ('secret', 'isTop', 'finished', 'finishReading'))
                           for channel in ('native', 'web'))):
                self.report['phase'] = 'mark_unverified'
                return self.report
            self.bound(target)
            self.report['phase'] = 'restore_pending'
            plan = dict(selection=plan['selection'], record=dict(kind='restore'), body=request(target, True),
                        baseline=dict(snapshot_hash=hash_value(after)))
            self.report['status_posts'] += 1
            response = self.send('restore', plan)
            self.report['restore_acknowledged'] = acknowledged(response)
            restored = self.snapshot(target)
            if self.report['restore_acknowledged'] and restored == before and restored == self.snapshot(target):
                self.report.update(result='PASS', phase='restored')
            else:
                self.report['phase'] = 'restore_unverified'
        except Exception:
            pass
        return self.report
