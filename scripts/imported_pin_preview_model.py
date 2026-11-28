"""Read-only independent model of imported-book pin previews; no transport."""
from copy import deepcopy
import math
import re

from finish_change_contract import flags, position_hash
from shelf_flag_change_contract import position, state_hash
from thought_edit_contract import digest
from verify_reader_progress import find_node

FIELDS = ('readingTime', 'recordReadingTime', 'ttsTime', 'isStartReading', 'startReadingTime',
          'summary', 'chapterTitle', 'readUpdateTime', 'finishReading', 'reading', 'readStatus',
          'readingStatus', 'markStatus')


def valid_id(identity):
    return isinstance(identity, str) and re.fullmatch(r'CB_[A-Za-z0-9]{1,64}', identity) is not None


def observation_hash(progress, identity):
    if not valid_id(identity): raise ValueError('imported_pin_preview/target')
    point = position(progress, identity)
    node = find_node(progress, identity)
    parts = ['imported-pin-progress-v1', position_hash(point)]
    for source in (progress, node):
        if not isinstance(source, dict): raise ValueError('imported_pin_preview/progress')
        for field in FIELDS:
            value = source.get(field)
            if field not in source: encoded = 'missing'
            elif type(value) is bool: encoded = 'bool:1' if value else 'bool:0'
            elif type(value) in (int, float) and math.isfinite(value): encoded = 'number:' + format(float(value), '.17g')
            elif isinstance(value, str) and len(value.encode()) <= 16384 and '\0' not in value: encoded = 'string:' + value
            else: raise ValueError('imported_pin_preview/progress')
            parts.extend((field, encoded))
    return digest(parts)


def request_hash(identity, desired):
    if not valid_id(identity) or type(desired) is not bool: raise ValueError('imported_pin_preview/target')
    return digest(['shelf-flag-request-v1', 'pinned', identity, 0 if desired else 1])


def make(source, progress, identity, desired):
    if not valid_id(identity) or type(desired) is not bool: raise ValueError('imported_pin_preview/target')
    snapshot = flags(source);row = snapshot.get(identity)
    if not row or row['pinned'].get('reason') == 'invalid': raise ValueError('imported_pin_preview/state')
    before = row['pinned'].get('value', 'missing')
    if type(before) is not bool and before != 'missing' or not desired and before is not True:
        raise ValueError('imported_pin_preview/state')
    if any(flag.get('reason') == 'invalid' for item in snapshot.values() for flag in item.values()):
        raise ValueError('imported_pin_preview/state')
    expected = deepcopy(source);target = next(row for row in expected['books'] if str(row['bookId']) == identity)
    target['isTop'] = int(desired);after = state_hash(expected);alternate = after
    if not desired:
        del target['isTop'];alternate = state_hash(expected)
    return {'kind': 'pinned', 'book_id': identity, 'before': before, 'desired': desired,
            'before_hash': state_hash(source), 'after_hash': after, 'alternate_hash': alternate,
            'position_hash': observation_hash(progress, identity), 'request_hash': request_hash(identity, desired)}


def plans(source, progress, identity):
    first = make(source, progress, identity, True);changed = deepcopy(source)
    next(row for row in changed['books'] if str(row['bookId']) == identity)['isTop'] = 1
    return [first, make(changed, progress, identity, False)]


def valid_metadata(value):
    keys = {'kind', 'book_id', 'before', 'desired', 'before_hash', 'after_hash', 'alternate_hash', 'position_hash', 'request_hash'}
    if not isinstance(value, dict) or set(value) != keys or value['kind'] != 'pinned' or not valid_id(value['book_id']) \
            or type(value['desired']) is not bool: return False
    before = value['before']
    if type(before) is not bool and before != 'missing' or not value['desired'] and before is not True: return False
    if any(not isinstance(value[key], str) or not re.fullmatch(r'[a-f0-9]{64}', value[key])
           for key in ('before_hash', 'after_hash', 'alternate_hash', 'position_hash', 'request_hash')): return False
    return (not value['desired'] or value['alternate_hash'] == value['after_hash']) \
        and value['request_hash'] == request_hash(value['book_id'], value['desired'])
