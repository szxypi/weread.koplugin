"""Bounded, single-book imported cloud-pin roundtrip; no transport here."""
from copy import deepcopy
import re
import time

from cloud_group_contract import project
from finish_change_contract import flags
from personal_upload_trial import hash_value
from verify_finish_roundtrip import acknowledged
from verify_pin_preflight import reading_fingerprint


def target_id(value):
    return isinstance(value, str) and re.fullmatch(r'CB_[A-Za-z0-9]{1,64}', value) is not None


def request(target, pinned):
    if not target_id(target) or type(pinned) is not bool:
        raise ValueError('imported_pin/target')
    return {'bookIds': [target], 'albumIds': [], 'archiveIds': [], 'isDel': 0 if pinned else 1}


def projection(raw, target):
    if not target_id(target) or not isinstance(raw, dict) or not isinstance(raw.get('books'), list):
        raise ValueError('imported_pin/shelf')
    shelf = deepcopy(raw)
    rows = [row for row in shelf['books'] if isinstance(row, dict) and row.get('bookId') == target]
    if len(rows) != 1:
        raise ValueError('imported_pin/identity')
    state = flags(shelf)[target]['pinned']
    if state not in ({'reason': 'missing'}, {'value': True}, {'value': False}):
        raise ValueError('imported_pin/state')
    rows[0].pop('isTop', None)
    return project(shelf), state


def sample(observe, current, target):
    if current() is not True:
        raise ValueError('imported_pin/session')
    result = observe(target)
    if not isinstance(result, dict) or set(result) != {'native', 'web', 'progress'}:
        raise ValueError('imported_pin/read')
    native, native_pin = projection(result['native'], target)
    web, web_pin = projection(result['web'], target)
    progress = result['progress']
    book = progress.get('book') if isinstance(progress, dict) else None
    if not isinstance(book, dict) or book.get('bookId', target) != target:
        raise ValueError('imported_pin/progress')
    if current() is not True:
        raise ValueError('imported_pin/session')
    return {'native': native, 'web': web, 'native_pin': native_pin, 'web_pin': web_pin,
            'progress_hash': reading_fingerprint(progress)}


def run(owner, target, grant_hash, observe, send, intents, current, *, apply=False, sleep=time.sleep):
    report = {'result': 'UNVERIFIED', 'phase': 'preflight', 'writes_attempted': 0,
              'account_data_writes_limit': 2, 'no_automatic_replay': True}
    try:
        if (not target_id(target) or not isinstance(owner, str) or not re.fullmatch(r'[1-9][0-9]{0,19}', owner)
                or not re.fullmatch(r'[a-f0-9]{64}', grant_hash) or set(intents) != {'pin', 'restore'}
                or any(value.read()[0] is not None for value in intents.values())):
            raise ValueError('imported_pin/scope')
        before = sample(observe, current, target)
        if before != sample(observe, current, target) or before['native_pin'] != {'reason': 'missing'} \
                or before['web_pin'] != {'reason': 'missing'}:
            raise ValueError('imported_pin/baseline')
        report['baseline_verified'] = True
        if not apply:
            report.update(result='READ_ONLY_PREVIEW', phase='preview')
            return report
        state = before
        for kind, pinned in (('pin', True), ('restore', False)):
            if state != sample(observe, current, target):
                raise ValueError('imported_pin/changed')
            body = request(target, pinned)
            plan = {'selection': {'owner': owner, 'book_id': target, 'grant_hash': grant_hash},
                    'record': {'kind': kind}, 'body': body,
                    'baseline': {'snapshot_hash': hash_value(state), 'native_hash': hash_value(state['native']),
                                 'web_hash': hash_value(state['web']), 'progress_hash': state['progress_hash']}}
            report['phase'] = kind + '_pending'
            receipt = intents[kind].claim(plan)
            if current() is not True:
                raise ValueError('imported_pin/session')
            report['writes_attempted'] += 1
            response = send(kind, body)
            if not acknowledged(response):
                raise ValueError('imported_pin/receipt')
            receipt = intents[kind].advance(receipt, 'acknowledged')
            expected = deepcopy(before)
            if pinned:
                expected['native_pin'] = expected['web_pin'] = {'value': True}
            after = None
            for attempt in range(4):
                seen = sample(observe, current, target)
                if any(seen[key] != before[key] for key in ('native', 'web', 'progress_hash')):
                    raise ValueError('imported_pin/changed')
                if seen == expected and sample(observe, current, target) == expected:
                    after = seen
                    break
                if any(seen[key] not in (state[key], expected[key]) for key in ('native_pin', 'web_pin')):
                    raise ValueError('imported_pin/unconfirmed')
                if attempt < 3:
                    sleep(.5 * (attempt + 1))
            if after is None:
                raise ValueError('imported_pin/unconfirmed')
            intents[kind].advance(receipt, 'verified')
            report[kind + '_verified'] = True
            state = after
        report.update(result='PASS', phase='restored', bookshelf_groups_and_progress_unchanged=True)
    except Exception as error:
        allowed = {'imported_pin/target', 'imported_pin/shelf', 'imported_pin/identity', 'imported_pin/state',
                   'imported_pin/session', 'imported_pin/read', 'imported_pin/progress', 'imported_pin/scope',
                   'imported_pin/baseline', 'imported_pin/changed', 'imported_pin/receipt', 'imported_pin/unconfirmed'}
        report['reason'] = str(error) if str(error) in allowed else 'imported_pin/unavailable'
    return report
