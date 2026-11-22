"""Compare a stored progress digest with a bounded updateTime-only candidate.

The original response is not retained. A matching SHA-256 proves equality of
all other fields, assuming SHA-256 collision resistance; a miss proves nothing.
Neither the original candidate nor response is returned or written to disk.
"""
from copy import deepcopy
import hashlib
import re
import time

from secure_shelf_experiment import canonical
from verify_pin_preflight import progress_fingerprint


def matches_except_update_time(current,expected,*,newest=None,window=90*86400):
    if (not isinstance(expected,str) or not re.fullmatch('[a-f0-9]{64}',expected)
            or type(window) is not int or not 0<=window<=90*86400):raise ValueError('proof/input')
    # Also validates the optional volatile top-level server timestamp.
    progress_fingerprint(current)
    book=current.get('book')
    if not isinstance(book,dict) or type(book.get('updateTime')) is not int or book['updateTime']<0:
        raise ValueError('proof/shape')
    if newest is None:newest=int(time.time())
    if type(newest) is not int or newest<window:raise ValueError('proof/range')
    value=deepcopy(current);value.pop('timestamp',None)
    marker='__weread_update_time_candidate__'
    value['book']['updateTime']=marker;encoded=canonical(value);token=canonical(marker)
    if encoded.count(token)!=1:raise ValueError('proof/marker')
    prefix,suffix=encoded.split(token);base=hashlib.sha256(prefix);wanted=bytes.fromhex(expected)
    for candidate in range(newest,newest-window-1,-1):
        digest=base.copy();digest.update(str(candidate).encode('ascii'));digest.update(suffix)
        if digest.digest()==wanted:return True
    return False
