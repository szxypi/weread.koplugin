"""Read-only audit binding across same-device native credential renewal."""
import json
import re

from imported_pin_trial import request, target_id
from personal_upload_trial import hash_value


def record_hash(value):
    if not isinstance(value, dict) or not isinstance(value.get('plan'), dict):
        raise ValueError('imported_pin/record')
    return hash_value({key: value.get(key) for key in ('schema', 'scope', 'attempt', 'claimed_at', 'plan')})


def projection(owner, grant, pin, restore):
    if not isinstance(owner, str) or not re.fullmatch(r'[1-9][0-9]{0,19}', owner) or not isinstance(grant, dict) \
            or grant.get('vid') != owner or not isinstance(grant.get('deviceId'), str):
        raise ValueError('imported_pin/account')
    return {'schema': 1, 'owner': owner, 'device_hash': hash_value(grant['deviceId']),
            'pin_hash': record_hash(pin), 'restore_hash': record_hash(restore) if restore else None}


def create(owner, grant, pin, restore, backend):
    selection = pin['plan']['selection'];target = selection.get('book_id')
    if (not target_id(target) or selection != {'owner': owner, 'book_id': target, 'grant_hash': hash_value(grant)}
            or pin['plan'].get('record') != {'kind': 'pin'} or pin['plan'].get('body') != request(target, True)
            or restore and (restore['plan'].get('selection') != selection or restore['plan'].get('record') != {'kind': 'restore'}
                            or restore['plan'].get('body') != request(target, False))):
        raise ValueError('imported_pin/binding')
    value = projection(owner, grant, pin, restore)
    encoded = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    prior = backend.load()
    if prior is not None and prior != encoded:
        raise ValueError('imported_pin/binding_exists')
    if prior is None:
        backend.save(encoded)
    if backend.load() != encoded:
        raise ValueError('imported_pin/binding_save')
    return True


def permits(owner, grant, pin, restore, backend):
    try:
        raw = backend.load()
        if not isinstance(raw, bytes) or not 1 <= len(raw) <= 2048:
            return False
        return json.loads(raw) == projection(owner, grant, pin, restore)
    except Exception:
        return False
