"""Isolated one-shot CB historical-time guard; no transport or reset methods."""
from contextlib import nullcontext
import json,math,re,secrets,tempfile,time
from pathlib import Path

from annotation_experiment_model import canonical,digest
from cb_native_readtime_model import batch
from native_time_capture import hashed
from native_time_capture_evidence import validate_evidence
from readtime_upload_model import confirmed,integer,local_zone
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from txt_full_summary import digest as captured_digest
from verify_eink_renewal import validate_credentials
from verify_native_position_lua import equivalent
from web_shelf_contract import identity

SERVICE='org.codex.weread.cb-native-historical-dispatch-v1'
PROTOCOL='cb-native-historical-one-shot-v1'


def day(stamp):return (stamp+28800)//86400*86400-28800


def binding(bundle,grant,snapshot,now):
    if not isinstance(bundle,dict) or set(bundle)!={'plan','evidence'}:raise ValueError('cb_bundle/bundle')
    plan=bundle['plan'];validate_evidence(plan,bundle['evidence'],imported=True);validate_credentials(grant)
    if grant['vid']!=plan['owner'] or captured_digest(grant['deviceId'])!=plan['device_sha256']:raise ValueError('cb_bundle/owner')
    if not integer(now,1,4102444800) or now<plan['not_before'] or day(now)<=day(plan['start_time']):raise ValueError('cb_bundle/not_historical')
    fields={'native','web','counts','version','native_shelf','web_shelf','source','catalog'}
    if (not isinstance(snapshot,dict) or set(snapshot)!=fields or captured_digest(snapshot)!=plan['baseline_sha256']
            or snapshot['version']!=plan['book_version'] or snapshot['source']!=plan['raw_sha256']
            or any(not hashed(snapshot[key]) for key in ('native_shelf','web_shelf','source','catalog'))):raise ValueError('cb_bundle/baseline')
    counts=snapshot['counts']
    if (not isinstance(counts,dict) or set(counts)!={'readingTime','recordReadingTime','ttsTime'}
            or any(not integer(value,0,2**53-1) for value in counts.values())):raise ValueError('cb_bundle/counts')
    native,web=snapshot['native'],snapshot['web']
    keys={'chapter_uid','chapter_idx','chapter_offset','raw_percent','summary','chapterTitle'}
    if any(not isinstance(point,dict) or set(point)!=keys for point in (native,web)):raise ValueError('cb_bundle/position')
    for point in (native,web):
        if (identity(point['chapter_uid'])!=plan['chapter_uid'] or not integer(point['chapter_idx'],0,1000000)
                or not integer(point['chapter_offset'],0,2147483647) or type(point['raw_percent']) not in (int,float)
                or not math.isfinite(point['raw_percent']) or not 0<=point['raw_percent']<=100):raise ValueError('cb_bundle/position')
        for field in ('summary','chapterTitle'):
            value=point[field]
            if (not isinstance(value,dict) or set(value) not in ({'present'},{'present','value'}) or type(value['present']) is not bool
                    or value['present']!=('value' in value) or value['present'] and (not isinstance(value['value'],str)
                    or len(value['value'].encode())>16384 or '\0' in value['value'])):raise ValueError('cb_bundle/position')
    if (identity(native['chapter_uid'])!=identity(web['chapter_uid'])
            or any(native[key]!=web[key] for key in ('chapter_idx','chapter_offset','raw_percent','summary'))):
        raise ValueError('cb_bundle/position')
    if native['chapter_idx']!=plan['chapter_idx'] or not native['summary']['present']:raise ValueError('cb_bundle/summary')
    summary=native['summary']['value']
    if (not 1<=len(summary)<=512 or len(summary.encode())>2048
            or any(ord(char)<32 and char not in '\t\r\n' for char in summary)):raise ValueError('cb_bundle/summary')
    return dict(protocol=PROTOCOL,bundle_sha256=digest(bundle),grant_sha256=digest(grant),
                baseline_sha256=plan['baseline_sha256'],device_sha256=plan['device_sha256'],
                owner_sha256=digest(plan['owner']),not_before=plan['not_before'],seconds=plan['seconds'])


def verify_request(bundle,grant,snapshot,body,guest,config,now,zone):
    binding(bundle,grant,snapshot,now)
    if zone!='+08:00' or not isinstance(body,dict) or set(body)!={'books','timestamp','random','signature'}:raise ValueError('cb_bundle/request')
    books=body.get('books')
    if not isinstance(books,list) or len(books)!=1 or not isinstance(books[0],dict):raise ValueError('cb_bundle/request')
    book=books[0];stamp=book.get('timestamp');plan=bundle['plan']
    if (not integer(stamp,1,4102444800) or not 0<=now-stamp<30 or day(stamp)!=day(now)
            or stamp<plan['not_before']):raise ValueError('cb_bundle/clock')
    rows=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')} for row in plan['rows']]
    try:
        expected=batch(grant,plan['book_id'],rows,guest,config,stamp,book.get('random'),body.get('timestamp'),
                       body.get('random'),current_zone=zone,summary=snapshot['native']['summary']['value'])
    except (ValueError,TypeError,KeyError):raise ValueError('cb_bundle/request') from None
    if not equivalent(expected,body):raise ValueError('cb_bundle/request')
    return digest(body)


def validate_record(value):
    if (not isinstance(value,dict) or set(value)!={'schema','scope','attempt','phase','binding','request_sha256','claimed_at','ack_sha256'}
            or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
            or not isinstance(value['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
            or value['phase'] not in ('prepared','claimed','acknowledged')):raise StoreError('cb_bundle/record')
    b=value['binding'];keys={'protocol','bundle_sha256','grant_sha256','baseline_sha256','device_sha256','owner_sha256','not_before','seconds'}
    if (not isinstance(b,dict) or set(b)!=keys or b['protocol']!=PROTOCOL
            or any(not hashed(b[key]) for key in ('bundle_sha256','grant_sha256','baseline_sha256','device_sha256','owner_sha256'))
            or not integer(b['not_before'],1,4102444800) or not integer(b['seconds'],5,12)):raise StoreError('cb_bundle/record')
    if value['phase']=='prepared':
        if any(value[key] is not None for key in ('request_sha256','claimed_at','ack_sha256')):raise StoreError('cb_bundle/record')
    elif not hashed(value['request_sha256']) or not integer(value['claimed_at'],b['not_before'],4102444800):raise StoreError('cb_bundle/record')
    elif value['phase']=='claimed' and value['ack_sha256'] is not None:raise StoreError('cb_bundle/record')
    elif value['phase']=='acknowledged' and not hashed(value['ack_sha256']):raise StoreError('cb_bundle/record')
    return value


class DispatchGate:
    def __init__(self,backend=None,lock=None,*,clock=time.time,zone=local_zone):
        real=backend is None or isinstance(backend,MacKeychain)
        if real and (clock is not time.time or zone is not local_zone):raise ValueError('cb_bundle/clock_override')
        if real and lock is not None:raise ValueError('cb_bundle/lock_override')
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-cb-native-historical-dispatch-'+ACCOUNT+'.lock')
        self.lock=(lambda:project_lock(path)) if real else lock or nullcontext
        self.clock,self.zone=clock,zone
    def _wall_clock(self):
        if isinstance(self.backend,MacKeychain) and (self.clock is not time.time or self.zone is not local_zone):raise ValueError('cb_bundle/clock_override')
        return int(self.clock()),self.zone()
    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            return validate_record(json.loads(raw)),raw
        except Exception:raise StoreError('cb_bundle/record') from None
    def _write(self,value):
        raw=canonical(validate_record(value));self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('cb_bundle/readback')
        self._read();return Receipt(raw)
    def read(self):
        with self.lock():
            value,raw=self._read();return value,Receipt(raw) if raw is not None else None
    def preview(self,bundle,grant,snapshot,body,guest,config):
        now,zone=self._wall_clock();return verify_request(bundle,grant,snapshot,body,guest,config,now,zone)
    def reserve(self,bundle,grant,snapshot):
        now,zone=self._wall_clock();bound=binding(bundle,grant,snapshot,now)
        if zone!='+08:00':raise ValueError('cb_bundle/zone')
        with self.lock():
            if self._read()!=(None,None):raise StoreError('cb_bundle/consumed')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',binding=bound,
                                    request_sha256=None,claimed_at=None,ack_sha256=None))
    def claim(self,receipt,bundle,grant,snapshot,body,guest,config):
        with self.lock():
            value,raw=self._read();now,zone=self._wall_clock()
            if (not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!='prepared'
                    or value['binding']!=binding(bundle,grant,snapshot,now)):raise StoreError('cb_bundle/changed')
            request_hash=verify_request(bundle,grant,snapshot,body,guest,config,now,zone)
            now,zone=self._wall_clock()
            if verify_request(bundle,grant,snapshot,body,guest,config,now,zone)!=request_hash:raise ValueError('cb_bundle/request')
            value.update(phase='claimed',request_sha256=request_hash,claimed_at=now);return self._write(value)
    def assert_claim_current(self,receipt,bundle,grant,snapshot,body,guest,config):
        with self.lock():
            value,raw=self._read();now,zone=self._wall_clock()
            if (not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!='claimed'
                    or value['binding']!=binding(bundle,grant,snapshot,now)
                    or verify_request(bundle,grant,snapshot,body,guest,config,now,zone)!=value['request_sha256']):
                raise StoreError('cb_bundle/changed')
            return True
    def acknowledge(self,receipt,response):
        if not confirmed(response):raise ValueError('cb_bundle/ack')
        with self.lock():
            value,raw=self._read()
            if not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!='claimed':raise StoreError('cb_bundle/changed')
            value.update(phase='acknowledged',ack_sha256=digest(response));return self._write(value)
