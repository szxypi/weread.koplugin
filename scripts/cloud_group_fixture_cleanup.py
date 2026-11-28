"""One-shot cleanup plan for the separately owned old group fixture.

The unresolved group request is not retried or marked successful. A fresh
baseline binds the exact fixture, both shelf projections and original records.
"""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import tempfile
import time

from cloud_group_contract import canonical, digest, project, temporary_name
from cloud_group_nonempty_workflow import strip_fixture
from cloud_group_trial import _cross_channel
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain, StoreError
from verify_cb_progress import cb_id

SERVICE='org.codex.weread.group-fixture-orphan-cleanup-v1'
HASHES={'owner','target','grant','group','upload','note','native_before','web_before','native_after','web_after'}


def validate_plan(value):
    if not isinstance(value,dict) or set(value)!=HASHES or any(
        not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in HASHES):
        raise ValueError('group_fixture_cleanup/plan')
    return value


def project_before(raw,target,names):
    if not cb_id(target) or not isinstance(names,(list,tuple)) or len(names)!=2 or any(not temporary_name(n) for n in names):
        raise ValueError('group_fixture_cleanup/scope')
    if not isinstance(raw,dict) or set(raw)!={'native','web'}:raise ValueError('group_fixture_cleanup/shelf')
    full={k:project(raw[k]) for k in ('native','web')}
    if not _cross_channel(full['native'],full['web']):raise ValueError('group_fixture_cleanup/channels')
    for value in full.values():
        if (target not in value['members'] or any(target in row['bookIds'] or row['name'] in names
                                                    for row in value['groups'].values())):
            raise ValueError('group_fixture_cleanup/occupied')
    stripped={k:strip_fixture(raw[k],target) for k in ('native','web')}
    return full,stripped


def project_after(raw,target,names):
    if not isinstance(raw,dict) or set(raw)!={'native','web'}:raise ValueError('group_fixture_cleanup/shelf')
    full={k:project(raw[k]) for k in ('native','web')}
    for value in full.values():
        if any(target in row['bookIds'] or row['name'] in names for row in value['groups'].values()):
            raise ValueError('group_fixture_cleanup/occupied')
        if target in value['members']:raise ValueError('group_fixture_cleanup/not_removed')
    if not _cross_channel(full['native'],full['web']):raise ValueError('group_fixture_cleanup/channels')
    return full


def make_plan(owner,grant,target,group,upload,notes,full,stripped):
    return validate_plan(dict(owner=digest(owner),target=digest(target),grant=digest(grant),group=digest(group),upload=digest(upload),
                              note=digest(notes),native_before=digest(full['native']),web_before=digest(full['web']),
                              native_after=digest(stripped['native']),web_after=digest(stripped['web'])))


class Intent:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-group-fixture-cleanup-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=4096:raise ValueError()
            value=json.loads(raw)
            if (set(value)!={'schema','scope','phase','plan'} or type(value['schema']) is not int or value['schema']!=1
                    or value['scope']!=ACCOUNT or value['phase'] not in ('prepared','claimed','verified')):raise ValueError()
            validate_plan(value['plan']);return value,raw
        except (ValueError,TypeError,KeyError,UnicodeError):raise StoreError('group_fixture_cleanup/invalid') from None
    def read(self):
        with self.lock():return self._read()
    def _save(self,value):
        raw=canonical(value);self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('group_fixture_cleanup/readback')
        self._read();return raw
    def reserve(self,plan):
        validate_plan(plan)
        with self.lock():
            if self._read()[0] is not None:raise StoreError('group_fixture_cleanup/consumed')
            return self._save(dict(schema=1,scope=ACCOUNT,phase='prepared',plan=plan))
    def advance(self,receipt,phase):
        with self.lock():
            value,raw=self._read()
            if (not value or raw!=receipt or (value['phase'],phase) not in (('prepared','claimed'),('claimed','verified'))):
                raise StoreError('group_fixture_cleanup/stale')
            value['phase']=phase;return self._save(value)


def verified_for(intent,group,upload,owner):
    value,_receipt=intent.read()
    if not value or value['phase']!='verified' or not isinstance(group,dict) or not isinstance(upload,dict):return False
    plan=value['plan']
    return (plan['owner']==digest(owner) and plan['target']==digest(group.get('target'))
            and plan['group']==digest(group) and plan['upload']==digest(upload))


def execute(owner,grant,target,group,upload,names,intent,current,read_pair,read_notes,send,*,apply=False,sleep=time.sleep):
    if type(apply) is not bool or intent.read()[0] is not None or not current():raise ValueError('group_fixture_cleanup/preflight')
    raw=read_pair();full,stripped=project_before(raw,target,names)
    again,again_stripped=project_before(read_pair(),target,names)
    if full!=again or stripped!=again_stripped:raise ValueError('group_fixture_cleanup/changed')
    notes=read_notes()
    if not isinstance(notes,dict) or notes.get('unstarted') is not True or notes.get('empty') is not True or notes!=read_notes() or not current():
        raise ValueError('group_fixture_cleanup/notes')
    plan=make_plan(owner,grant,target,group,upload,notes,full,stripped)
    if not apply:return dict(result='READ_ONLY_PREVIEW',cleanup_posts=0,stable_shelf=True,fixture_unstarted=True)
    receipt=intent.reserve(plan)
    check,check_stripped=project_before(read_pair(),target,names)
    if check!=full or check_stripped!=stripped or read_notes()!=notes or not current():raise ValueError('group_fixture_cleanup/changed')
    receipt=intent.advance(receipt,'claimed')
    if not current():raise ValueError('group_fixture_cleanup/stale')
    ack=send(target,receipt,plan)
    for attempt in range(3):
        if attempt:sleep(.5*attempt)
        try:after=project_after(read_pair(),target,names);break
        except ValueError as error:
            if str(error)!='group_fixture_cleanup/not_removed' or attempt==2:raise
    after_again=project_after(read_pair(),target,names)
    if (after!=after_again or after!=stripped or ack is not True or not current()):raise ValueError('group_fixture_cleanup/unconfirmed')
    intent.advance(receipt,'verified')
    return dict(result='FIXTURE_CLEANED',cleanup_posts=1,fixture_removed=True,other_shelf_state_unchanged=True,
                original_group_request_unresolved=True,no_replay=True)
