"""Bind the exact already-consumed group trial and its imported fixture.

This is a comparison model, not a journal reader or permission to change one.
"""
import hashlib
import json
import re
from copy import deepcopy

from annotation_experiment_model import digest
from personal_upload_trial import Receipt,hash_value
from verify_cb_progress import cb_id

FIELDS={'target','owner_sha256','upload_sha256','group_sha256','old_sha256'}


def from_journals(bundle,upload,upload_raw,group,group_raw,old,old_raw):
    try:
        owner=bundle['plan']['owner']
        if not isinstance(upload_raw,Receipt):raise ValueError()
        upload_raw=upload_raw.raw
        entries=((upload,upload_raw),(group,group_raw),(old,old_raw))
        if any(not isinstance(state,dict) or not isinstance(raw,bytes) or not 0<len(raw)<=65536
               or json.loads(raw)!=state for state,raw in entries):raise ValueError()
        if (upload['phase']!='imported' or not cb_id(upload['target']) or upload['plan']['owner']!=owner
                or group['owner']!=owner or group['target']!=upload['target']
                or group['upload_attempt']!=upload['attempt'] or group['upload_plan_hash']!=hash_value(upload['plan'])
                or group['phase']!='create_claimed' or group['dispatched'] is not True
                or old['owner']!=owner or old['phase']!='closed_unverified'):
            raise ValueError()
        return {'target':upload['target'],'owner_sha256':digest(owner),
                'upload_sha256':hashlib.sha256(upload_raw).hexdigest(),
                'group_sha256':hashlib.sha256(group_raw).hexdigest(),
                'old_sha256':hashlib.sha256(old_raw).hexdigest()}
    except (ValueError,TypeError,KeyError,UnicodeError):
        raise ValueError('bundle_trial_scope/journals') from None


def validate(bundle,scope):
    if (not isinstance(scope,dict) or set(scope)!=FIELDS or not cb_id(scope['target'])
            or scope['owner_sha256']!=digest(bundle['plan']['owner'])
            or any(not isinstance(scope[k],str) or not re.fullmatch('[a-f0-9]{64}',scope[k])
                   for k in ('owner_sha256','upload_sha256','group_sha256','old_sha256'))):
        raise ValueError('bundle_trial_scope/scope')
    return scope


class LiveTrialReader:
    """Read and bind all three existing journals without changing their state."""
    def __init__(self,bundle,current,*,upload=None,group=None,old=None,receipt=None):
        from cloud_group_fixture import Journal as UploadJournal
        from cloud_group_nonempty_journal import Journal as GroupJournal
        from cloud_group_journal import Journal as OldJournal
        from synthetic_format_trial import TargetReceipt
        if not callable(current):raise ValueError('bundle_trial_scope/current')
        self.bundle=deepcopy(bundle);self.bundle_hash=digest(bundle);self.current=current
        self.upload=upload if upload is not None else UploadJournal()
        self.group=group if group is not None else GroupJournal()
        self.old=old if old is not None else OldJournal()
        self.receipt=receipt if receipt is not None else TargetReceipt('epub',scope='group-fixture')

    def __call__(self):
        from cloud_group_fixture import binding
        if self.current() is not True or digest(self.bundle)!=self.bundle_hash:raise ValueError('bundle_trial_scope/stale')
        upload,upload_raw=binding(self.upload,self.receipt.backend)
        group,group_raw=self.group.read();old,old_raw=self.old.read()
        result=from_journals(self.bundle,upload,upload_raw,group,group_raw,old,old_raw)
        if (self.current() is not True or digest(self.bundle)!=self.bundle_hash
                or binding(self.upload,self.receipt.backend)!=(upload,upload_raw)
                or self.group.read()!=(group,group_raw) or self.old.read()!=(old,old_raw)):
            raise ValueError('bundle_trial_scope/stale')
        return result
