"""Two native TXT position slots with recovery data only in Keychain."""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile
from secure_weread_session import MacKeychain,ACCOUNT,StoreError
from secure_native_session import project_lock
from secure_shelf_experiment import canonical,Receipt
from readtime_upload_model import integer
from source_upload_candidate import identifier

POINT_FIELDS={'book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary'}
HASH_FIELDS={'owner_sha256','source_sha256','grant_sha256','shelf_sha256','catalog_sha256'}
PHASES={'prepared':0,'advance_pending':1,'advance_acknowledged':1,'advance_verified':1,'restore_pending':2,
    'restore_acknowledged':2,'restore_acknowledged_unverified_advance':2,'retired':2,'restored_advance_unverified':2,
    'closed_advance_unverified':1,'closed_restore_unverified':2,'aborted':0}
TRANSITIONS={('prepared','advance_pending'),('prepared','aborted'),('advance_pending','advance_acknowledged'),('advance_acknowledged','advance_verified'),
    ('advance_verified','restore_pending'),('advance_pending','restore_pending'),
    ('advance_acknowledged','restore_pending'),('restore_pending','restore_acknowledged'),('restore_pending','restore_acknowledged_unverified_advance'),
    ('restore_acknowledged','retired'),('restore_acknowledged_unverified_advance','restored_advance_unverified'),
    ('advance_pending','closed_advance_unverified'),('advance_verified','closed_advance_unverified'),('advance_acknowledged','closed_advance_unverified'),('restore_pending','closed_restore_unverified')}


def point(value):
    if not isinstance(value,dict) or set(value)!=POINT_FIELDS:raise StoreError('txt_roundtrip/point')
    if any(not isinstance(value[k],str) or identifier(value[k])!=value[k] for k in ('book_id','chapter_uid')):raise StoreError('txt_roundtrip/point')
    if (not integer(int(value['chapter_uid']),1,2**53-1) or not integer(value['chapter_idx'],0,1000000)
            or not integer(value['chapter_offset'],0,2147483647) or type(value['raw_percent']) not in (int,float) or not 0<=value['raw_percent']<=100
            or not isinstance(value['summary'],str) or not 2<=len(value['summary'])<=512 or len(value['summary'].encode())>2048
            or any(ord(c)<32 and c not in '\t\r\n' for c in value['summary'])):raise StoreError('txt_roundtrip/point')


def validate_plan(value,protocol):
    if not isinstance(value,dict) or set(value)!=HASH_FIELDS|{'protocol','baseline','target','counts','version','chapter_progress'} or value['protocol']!=protocol:raise StoreError('txt_roundtrip/plan')
    if any(not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in HASH_FIELDS):raise StoreError('txt_roundtrip/plan')
    point(value['baseline']);point(value['target']);original,target=value['baseline'],value['target']
    if (any(original[k]!=target[k] for k in POINT_FIELDS-{'chapter_offset','summary'}) or target['chapter_offset']!=original['chapter_offset']+1
            or len(target['summary'])!=len(original['summary']) or target['summary'][:-1]!=original['summary'][1:]):raise StoreError('txt_roundtrip/adjacent')
    if (not isinstance(value['counts'],dict) or set(value['counts'])!={'readingTime','recordReadingTime','ttsTime'}
            or any(not integer(n,0,2**53-1) for n in value['counts'].values()) or not integer(value['version'],0,2147483647)
            or value['chapter_progress'] is not None and (type(value['chapter_progress']) not in (int,float) or not 0<=value['chapter_progress']<=100)):raise StoreError('txt_roundtrip/plan')


class NativeTxtRoundtripStore:
    service='org.codex.weread.goal-native-txt-roundtrip-v1'
    protocol='native-txt-adjacent-restore-zero-time-v1'
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=self.service,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-txt-roundtrip-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=16384:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','attempt','phase','posts','plan'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or value['phase'] not in PHASES or not integer(value['posts'],0,2) or value['posts']!=PHASES[value['phase']]
                    or not isinstance(value['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',value['attempt'])):raise ValueError()
            validate_plan(value['plan'],self.protocol);return value,raw
        except Exception:raise StoreError('txt_roundtrip/intent_invalid') from None
    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None
    def pending(self):
        value,_r=self.read();return value is not None and value['phase'] not in ('retired','restored_advance_unverified','aborted','closed_advance_unverified','closed_restore_unverified')
    def _write(self,value):
        raw=canonical(value);self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('txt_roundtrip/readback')
        self._load();return Receipt(raw)
    def reserve(self,plan):
        validate_plan(plan,self.protocol)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('txt_roundtrip/consumed')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',posts=0,plan=plan))
    def advance(self,receipt,before,after):
        if (before,after) not in TRANSITIONS:raise StoreError('txt_roundtrip/phase')
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.pending or value['phase']!=before:raise StoreError('txt_roundtrip/replaced')
            value['phase'],value['posts']=after,PHASES[after];return self._write(value)
