"""One-shot public-account shelf trial contracts; no transport or credentials I/O."""
from contextlib import nullcontext
from dataclasses import dataclass
import hashlib,json,re,secrets,tempfile
from pathlib import Path
from finish_change_contract import flags,flags_hash
from native_shelf_trial import group_hash
from secure_native_session import project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from verify_eink_shelf_write import snapshot
from verify_owner_shelf_membership import members_digest

SERVICE='org.codex.weread.goal-mp-subscription-trial-v1'
FIELDS={'owner','account_id','members_sha256','flags_sha256','groups_sha256','grant_sha256','count'}
TRANSITIONS={'prepared':'add_pending','add_pending':'add_confirmed','add_confirmed':'remove_pending','remove_pending':'restored'}


def valid_id(value):
    return isinstance(value,str) and re.fullmatch(r'MP_WXS_[1-9][0-9]{0,19}',value) is not None


def grant_digest(credentials):
    if not isinstance(credentials,dict):raise ValueError('mp_subscription/grant')
    return hashlib.sha256(canonical(credentials)).hexdigest()


def validate(plan):
    if (not isinstance(plan,dict) or set(plan)!=FIELDS or not isinstance(plan['owner'],str)
            or re.fullmatch(r'[1-9][0-9]{0,19}',plan['owner']) is None or not valid_id(plan['account_id'])
            or type(plan['count']) is not int or not 0<=plan['count']<=10000):raise ValueError('mp_subscription/plan')
    if any(not isinstance(plan[k],str) or re.fullmatch('[a-f0-9]{64}',plan[k]) is None
           for k in ('members_sha256','flags_sha256','groups_sha256','grant_sha256')):raise ValueError('mp_subscription/plan')
    return plan


def projection(source,target):
    if not valid_id(target):raise ValueError('mp_subscription/target')
    rows=snapshot(source);marked=flags(source)
    if any(flag.get('reason')=='invalid' for row in marked.values() for flag in row.values()):raise ValueError('mp_subscription/flags')
    present=target in rows;rows.pop(target,None);marked.pop(target,None)
    return dict(present=present,count=len(rows),members_sha256=members_digest(rows),
                flags_sha256=flags_hash(marked),groups_sha256=group_hash(source,target))


def prepare(credentials,source,target):
    data=projection(source,target)
    if data.pop('present'):raise ValueError('mp_subscription/already_present')
    return validate(dict(owner=credentials['vid'],account_id=target,grant_sha256=grant_digest(credentials),**data))


def check(plan,credentials,source,present):
    validate(plan)
    if type(present) is not bool or credentials.get('vid')!=plan['owner'] or grant_digest(credentials)!=plan['grant_sha256']:
        raise ValueError('mp_subscription/grant')
    data=projection(source,plan['account_id'])
    if data.pop('present') is not present or any(data[k]!=plan[k] for k in data):raise ValueError('mp_subscription/changed')
    return True


@dataclass(frozen=True,repr=False)
class Receipt:
    raw:bytes


class Journal:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-mp-subscription-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            value=json.loads(raw)
            if (not isinstance(raw,bytes) or not 0<len(raw)<=8192 or not isinstance(value,dict)
                    or set(value)!={'schema','scope','attempt','phase','plan'} or type(value['schema']) is not int or value['schema']!=1
                    or value['scope']!=ACCOUNT or not isinstance(value['attempt'],str)
                    or re.fullmatch('[a-f0-9]{32}',value['attempt']) is None
                    or value['phase'] not in ('prepared','add_pending','add_confirmed','remove_pending','restored')):raise ValueError()
            validate(value['plan']);return value,raw
        except (ValueError,KeyError,TypeError,UnicodeError):raise StoreError('mp_subscription/journal_invalid') from None
    def read(self):
        with self.lock():
            value,raw=self._read();return value,Receipt(raw) if raw else None
    def reserve(self,plan):
        validate(plan)
        with self.lock():
            if self._read()[0] is not None:raise StoreError('mp_subscription/already_reserved')
            raw=canonical(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',plan=plan))
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('mp_subscription/readback')
            self._read();return Receipt(raw)
    def advance(self,receipt,next_phase):
        with self.lock():
            value,raw=self._read()
            if not isinstance(receipt,Receipt) or value is None or raw!=receipt.raw or TRANSITIONS.get(value['phase'])!=next_phase:
                raise StoreError('mp_subscription/stale')
            value['phase']=next_phase;updated=canonical(value);self.backend.save(updated)
            if self.backend.load()!=updated:raise StoreError('mp_subscription/readback')
            self._read();return Receipt(updated)
