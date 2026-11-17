"""One-shot personal-book upload intent and shelf projections; no network."""
from contextlib import nullcontext
from copy import deepcopy
from dataclasses import dataclass
import hashlib,json,re,secrets,tempfile
from pathlib import Path
from finish_change_contract import flags,flags_hash
from secure_native_session import project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from shelf_flag_change_contract import groups_hash
from verify_eink_shelf_write import snapshot
from verify_owner_shelf_membership import members_digest

SERVICE='org.codex.weread.goal-personal-upload-trial-v1'
STEPS={'prepared':'credential_pending','credential_pending':'credential_ready','credential_ready':'upload_pending',
       'upload_pending':'uploaded','uploaded':'notify_pending','notify_pending':'imported','imported':'cleanup_pending','cleanup_pending':'restored'}
FIELDS={'owner','name','body_sha256','members_sha256','flags_sha256','groups_sha256','grant_sha256','count'}


def hash_value(value):return hashlib.sha256(canonical(value)).hexdigest()
def valid_book(value):return isinstance(value,str) and 1<=len(value)<=128 and value!='0' and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*',value) is not None and not value.startswith('MP_')


def projection(source,target=None):
    rows=snapshot(source);marked=flags(source)
    if any(flag.get('reason')=='invalid' for row in marked.values() for flag in row.values()):raise ValueError('personal_upload/flags')
    present=target is not None and target in rows
    if target is not None:
        if not valid_book(target):raise ValueError('personal_upload/target')
        rows.pop(target,None);marked.pop(target,None)
    clean=deepcopy(source)
    for group in clean.get('archive',[]):
        for field in ('bookIds','albumIds'):
            if field in group:group[field]=[v for v in group[field] if str(v)!=target]
    return dict(present=present,count=len(rows),members_sha256=members_digest(rows),flags_sha256=flags_hash(marked),groups_sha256=groups_hash(clean))


def validate(plan):
    if (not isinstance(plan,dict) or set(plan)!=FIELDS or not isinstance(plan['owner'],str)
            or re.fullmatch(r'[1-9][0-9]{0,19}',plan['owner']) is None
            or not isinstance(plan['name'],str) or re.fullmatch(r'KOReaderSynthetic-[a-f0-9]{16}\.txt',plan['name']) is None
            or type(plan['count']) is not int or not 0<=plan['count']<=10000):raise ValueError('personal_upload/plan')
    for k in ('body_sha256','members_sha256','flags_sha256','groups_sha256','grant_sha256'):
        if not isinstance(plan[k],str) or re.fullmatch('[a-f0-9]{64}',plan[k]) is None:raise ValueError('personal_upload/plan')
    return plan


def prepare(credentials,source,name,body):
    data=projection(source);data.pop('present')
    if not isinstance(body,bytes) or not 1<=len(body)<=1024:raise ValueError('personal_upload/body')
    return validate(dict(owner=credentials['vid'],name=name,body_sha256=hashlib.sha256(body).hexdigest(),
                         grant_sha256=hash_value(credentials),**data))


def check(plan,credentials,source,target=None,expected=False):
    validate(plan)
    if type(expected) is not bool or credentials.get('vid')!=plan['owner'] or hash_value(credentials)!=plan['grant_sha256']:
        raise ValueError('personal_upload/grant')
    data=projection(source,target);present=data.pop('present')
    if present is not expected or any(data[k]!=plan[k] for k in data):raise ValueError('personal_upload/changed')
    return True


@dataclass(frozen=True,repr=False)
class Receipt:raw:bytes


class Journal:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-personal-upload-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            v=json.loads(raw)
            if (not isinstance(raw,bytes) or not 0<len(raw)<=8192 or not isinstance(v,dict)
                    or set(v)!={'schema','scope','attempt','phase','plan','target','object_sha256'}
                    or type(v['schema']) is not int or v['schema']!=1 or v['scope']!=ACCOUNT
                    or not isinstance(v['attempt'],str) or re.fullmatch('[a-f0-9]{32}',v['attempt']) is None
                    or v['phase'] not in ('prepared','credential_pending','credential_ready','upload_pending','uploaded','notify_pending','imported','cleanup_pending','restored')):raise ValueError()
            validate(v['plan'])
            if v['phase'] in ('imported','cleanup_pending','restored'):
                if not valid_book(v['target']):raise ValueError()
            elif v['target'] is not None:raise ValueError()
            if v['phase'] not in ('prepared','credential_pending'):
                if not isinstance(v['object_sha256'],str) or re.fullmatch('[a-f0-9]{64}',v['object_sha256']) is None:raise ValueError()
            elif v['object_sha256'] is not None:raise ValueError()
            return v,raw
        except (ValueError,KeyError,TypeError,UnicodeError):raise StoreError('personal_upload/journal_invalid') from None
    def read(self):
        with self.lock():
            value,raw=self._read();return value,Receipt(raw) if raw else None
    def reserve(self,plan):
        validate(plan)
        with self.lock():
            if self._read()[0] is not None:raise StoreError('personal_upload/already_reserved')
            raw=canonical(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',plan=plan,target=None,object_sha256=None))
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('personal_upload/readback')
            self._read();return Receipt(raw)
    def advance(self,receipt,phase,*,target=None,object_sha256=None):
        with self.lock():
            value,raw=self._read()
            if not isinstance(receipt,Receipt) or value is None or raw!=receipt.raw or STEPS.get(value['phase'])!=phase:
                raise StoreError('personal_upload/stale')
            if (phase=='imported')!=(target is not None) or (phase=='credential_ready')!=(object_sha256 is not None):
                raise StoreError('personal_upload/stale')
            if target is not None:value['target']=target
            if object_sha256 is not None:value['object_sha256']=object_sha256
            value['phase']=phase
            # Validate before changing the durable item, including new fields.
            raw_new=canonical(value)
            if phase=='imported' and not valid_book(target) or phase=='credential_ready' and (not isinstance(object_sha256,str) or re.fullmatch('[a-f0-9]{64}',object_sha256) is None):raise StoreError('personal_upload/stale')
            self.backend.save(raw_new)
            if self.backend.load()!=raw_new:raise StoreError('personal_upload/readback')
            self._read();return Receipt(raw_new)
