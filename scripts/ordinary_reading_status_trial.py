"""Four one-shot stages for an unstarted ordinary book outside the shelf.

The injected transport must enforce the exact target and claim each action
before dispatch. Proofs record observations, not inferred acknowledgements.
"""
from copy import deepcopy
import time

from cloud_group_contract import project
from personal_upload_trial import hash_value
from verify_personal_upload_trial import acknowledged

STAGES = ('add', 'mark', 'restore', 'remove')
COORDINATES = ('chapterUid', 'chapterIdx', 'chapterOffset', 'progress', 'summary',
               'readingTime', 'recordReadingTime', 'ttsTime')


def request(stage, identity):
    if stage not in STAGES or not isinstance(identity, str) or not identity.isascii() \
            or not identity.isdigit() or identity.startswith('0') or len(identity) > 20:
        raise ValueError('ordinary_reading/scope')
    if stage in ('add', 'remove'):
        return ('/shelf/add' if stage == 'add' else '/shelf/delete',
                {'bookIds': [identity], 'albumIds': [], 'archiveIds': []})
    return ('/book/markstatus', {'auto': 0, 'bookId': identity, 'finishInfo': 0,
                                'isCancel': int(stage == 'restore'), 'status': 2})


def strip(source, identity):
    project(source)
    copy = deepcopy(source)
    matches = [row for row in copy['books'] if str(row['bookId']) == identity]
    if len(matches) > 1:
        raise ValueError('ordinary_reading/target')
    copy['books'] = [row for row in copy['books'] if str(row['bookId']) != identity]
    for group in copy.get('archive', []):
        group['bookIds'] = [value for value in group['bookIds'] if str(value) != identity]
    return bool(matches), project(copy)


def progress(raw, identity):
    if not isinstance(raw, dict) or not isinstance(raw.get('book'), dict):
        raise ValueError('ordinary_reading/progress')
    book = raw['book']
    for node in (raw, book):
        if 'bookId' in node and str(node['bookId']) != identity:
            raise ValueError('ordinary_reading/identity')
    flag, stamp = book.get('isStartReading'), book.get('startReadingTime')
    if type(flag) is not int or flag not in (0, 1) or type(stamp) is not int or stamp < 0:
        raise ValueError('ordinary_reading/status')
    if any(type(book.get(key)) is not int or book[key] < 0 for key in ('readingTime', 'recordReadingTime', 'ttsTime')):
        raise ValueError('ordinary_reading/counters')
    return {'flag': flag, 'start_time': stamp,
            'position': {key: deepcopy(book[key]) for key in COORDINATES if key in book}}


def expected(stage, before, after, baseline):
    if any(after[key] != baseline[key] for key in ('native_shelf', 'web_shelf', 'marks', 'thoughts')):
        return False
    if before['progress']['position'] != after['progress']['position']:
        return False
    if stage == 'add':
        return not before['present'] and after['present'] and after['progress'] == before['progress']
    if stage == 'mark':
        return (before['present'] and after['present'] and before['target_flags'] == after['target_flags']
                and before['progress']['flag'] == 0 and after['progress']['flag'] == 1
                and after['progress']['start_time'] > 0)
    if stage == 'restore':
        return (before['present'] and after['present'] and before['target_flags'] == after['target_flags']
                and before['progress']['flag'] == 1 and after['progress'] == baseline['progress'])
    return before['present'] and not after['present'] and after['progress'] == baseline['progress']


def run(stage, plan, actions, proofs, current, observe, send, sleep=time.sleep):
    report = {'result': 'UNVERIFIED', 'phase': 'preflight', 'data_posts': 0,
              'acknowledged': False, 'independent_readback': False, 'no_automatic_replay': True}
    try:
        if stage not in STAGES or current() is not True:
            raise ValueError('ordinary_reading/scope')
        selection, baseline = plan['selection'], plan['baseline']
        identity = selection['book_id']
        path, body = request(stage, identity)
        index = STAGES.index(stage)
        if actions[stage].read()[0] is not None or proofs[stage].read()[0] is not None:
            raise ValueError('ordinary_reading/consumed')
        if any(actions[name].read()[0] is not None or proofs[name].read()[0] is not None for name in STAGES[index + 1:]):
            raise ValueError('ordinary_reading/scope')
        for name in STAGES[:index]:
            action_record, _ = actions[name].read()
            proof_record, _ = proofs[name].read()
            if (not action_record or action_record['phase'] != 'claimed' or not proof_record
                    or proof_record['phase'] != 'claimed' or action_record['plan']['selection'] != selection
                    or action_record['plan']['record'] != {'kind': name}
                    or action_record['plan']['body'] != request(name, identity)[1]
                    or proof_record['plan']['selection'] != selection
                    or proof_record['plan']['record']['kind'] != name + '_observed'):
                raise ValueError('ordinary_reading/proof')
        before = observe()
        if before != observe() or current() is not True:
            raise ValueError('ordinary_reading/unstable')
        if any(before[key] != baseline[key] for key in ('native_shelf', 'web_shelf', 'marks', 'thoughts')):
            raise ValueError('ordinary_reading/changed')
        if index == 0:
            if before['present'] or before['progress'] != baseline['progress']:
                raise ValueError('ordinary_reading/changed')
        else:
            proof, _ = proofs[STAGES[index - 1]].read()
            if (not proof or proof['plan']['selection'] != selection
                    or proof['plan']['record']['kind'] != STAGES[index - 1] + '_observed'
                    or proof['plan']['baseline']['snapshot_hash'] != hash_value(before)):
                raise ValueError('ordinary_reading/proof')
        if current() is not True or observe() != before:
            raise ValueError('ordinary_reading/changed')
        action = dict(selection=selection, record={'kind': stage}, body=body,
                      baseline={'snapshot_hash': hash_value(before)})
        # The transport must claim this exact plan before attempting the POST.
        report.update(phase='dispatch', data_posts=1)
        try:
            response = send(stage, path, action)
        except Exception:
            response = None
        report['acknowledged'] = acknowledged(response)
        after = None
        for attempt in range(3):
            if attempt:
                sleep(.5 * attempt)
            first, second = observe(), observe()
            if current() is not True or any(first[key] != baseline[key] for key in ('native_shelf','web_shelf','marks','thoughts')):
                raise ValueError('ordinary_reading/changed')
            if first == second and expected(stage, before, first, baseline):
                after = first
                break
        if after is None:
            report['phase'] = 'readback_unverified'
            return report
        report['independent_readback'] = True
        if stage == 'add' and not report['acknowledged']:
            report['phase'] = 'add_ack_unverified'
            return report
        action_record, _ = actions[stage].read()
        if (not action_record or action_record['phase'] != 'claimed' or action_record['plan'] != action):
            raise ValueError('ordinary_reading/claim')
        proof = dict(selection=selection, record={'kind': stage + '_observed', 'acknowledged': report['acknowledged']},
                     body={}, baseline={'snapshot_hash': hash_value(after)})
        proofs[stage].claim(proof)
        report.update(result='OBSERVED', phase='complete')
    except Exception:
        pass
    return report
