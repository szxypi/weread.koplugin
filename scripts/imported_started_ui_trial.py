"""One isolated imported-book native started-status roundtrip.

The caller binds the fixture and implements scoped reads, permanent claims and
one native UI dispatch. Every state transition is verified by two fresh reads.
"""
from copy import deepcopy

from personal_upload_trial import hash_value
from reading_status_fixture_trial import request


def plan(selection, kind, before):
    if kind not in ('mark', 'restore'):
        raise ValueError('imported_started/stage')
    return dict(selection=selection, record={'kind': kind}, body=request(selection['target'], kind == 'restore'),
                baseline={'snapshot_hash': hash_value(before)})


def initial(value):
    progress = value['progress'];position = progress['position']
    return (progress['flag'] == 0 and progress['start_time'] == 0
            and all(type(position.get(key)) is int and position[key] == 0
                    for key in ('chapterUid', 'chapterOffset', 'progress', 'readingTime', 'recordReadingTime', 'ttsTime'))
            and position.get('summary', '') == '' and value['marks_empty'] is True and value['thoughts_empty'] is True)


def marked(before, after):
    if not initial(before) or after['progress']['flag'] != 1 or type(after['progress']['start_time']) is not int \
            or after['progress']['start_time'] <= 0:
        return False
    expected = deepcopy(after);expected['progress']['flag'] = 0;expected['progress']['start_time'] = 0
    for key in ('isStartReading', 'startReadingTime'):
        if key in before['observed']: expected['observed'][key] = before['observed'][key]
        else: expected['observed'].pop(key, None)
    return expected == before


def run(selection, observe, send, proof, current):
    report = dict(result='UNVERIFIED', phase='preflight', status_posts=0, mark_ui_verified=False,
                  restore_ui_verified=False, independent_mark_readback=False, independent_restore_readback=False)
    try:
        before = observe()
        if current() is not True or not initial(before) or before != observe():
            raise ValueError('imported_started/baseline')
        report.update(phase='mark', status_posts=1)
        if send('mark', plan(selection, 'mark', before)) is not True:
            raise ValueError('imported_started/ui')
        report['mark_ui_verified'] = True
        after = observe()
        if current() is not True or after != observe() or not marked(before, after):
            raise ValueError('imported_started/mark')
        report['independent_mark_readback'] = True
        proof('mark', selection, after)
        if current() is not True: raise ValueError('imported_started/owner')
        report.update(phase='restore', status_posts=2)
        if send('restore', plan(selection, 'restore', after)) is not True:
            raise ValueError('imported_started/ui')
        report['restore_ui_verified'] = True
        restored = observe()
        if current() is not True or restored != observe() or restored != before:
            raise ValueError('imported_started/restore')
        report['independent_restore_readback'] = True
        proof('restore', selection, restored)
        report.update(result='PASS', phase='restored')
    except Exception:
        pass
    return report
