"""Durable single-dispatch guard for a fully evidenced native time bundle.

This component performs no I/O beyond its own Keychain journal. A future
supervisor must independently preflight the account and supply fresh signing
inputs; a journal reservation alone does not authorize or send anything.
"""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile
import time

from annotation_experiment_model import canonical, digest
from native_time_capture_evidence import validate_evidence
from readtime_upload_model import batch, confirmed, integer, local_zone
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain, StoreError
from txt_full_summary import digest as captured_digest
from verify_eink_renewal import validate_credentials
from verify_native_position_lua import equivalent

SERVICE='org.codex.weread.goal-native-time-bundle-dispatch-v1'
PROTOCOL='native-time-bundle-one-shot-v1'
HASH=re.compile(r'[a-f0-9]{64}\Z')


def day(stamp):return (stamp+28800)//86400*86400-28800


def binding(bundle,grant,now):
    if not isinstance(bundle,dict) or set(bundle)!={'plan','evidence'}:raise ValueError('bundle_gate/bundle')
    plan=bundle['plan'];validate_evidence(plan,bundle['evidence']);validate_credentials(grant)
    if (plan['format']!='web_xhtml' or grant['vid']!=plan['owner']
            or captured_digest(grant['deviceId'])!=plan['device_sha256']):raise ValueError('bundle_gate/owner_device')
    if (not integer(now,1,4102444800) or now<plan['not_before'] or day(now)<=day(plan['start_time'])):
        raise ValueError('bundle_gate/not_historical')
    return dict(protocol=PROTOCOL,bundle_sha256=digest(bundle),grant_sha256=digest(grant),
                device_sha256=plan['device_sha256'],owner_sha256=digest(plan['owner']),
                not_before=plan['not_before'],seconds=plan['seconds'])


def verify_request(bundle,grant,body,guest,config_token,now,zone):
    binding(bundle,grant,now)
    if zone!='+08:00' or not isinstance(body,dict) or set(body)!={'books','timestamp','random','signature'}:
        raise ValueError('bundle_gate/request')
    books=body.get('books')
    if not isinstance(books,list) or len(books)!=1 or not isinstance(books[0],dict):raise ValueError('bundle_gate/request')
    book=books[0];stamp=book.get('timestamp')
    if (not integer(stamp,1,4102444800) or not 0<=now-stamp<30 or day(stamp)!=day(now)
            or stamp<bundle['plan']['not_before']):raise ValueError('bundle_gate/clock')
    rows=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')} for row in bundle['plan']['rows']]
    try:
        expected=batch(grant,bundle['plan']['book_id'],rows,guest,config_token,stamp,book.get('random'),
                       body.get('timestamp'),body.get('random'),current_zone=zone)
    except (ValueError,TypeError,KeyError):raise ValueError('bundle_gate/request') from None
    if not equivalent(expected,body):raise ValueError('bundle_gate/request')
    return digest(body)


def validate_record(value):
    if (not isinstance(value,dict) or set(value)!={'schema','scope','attempt','phase','binding','request_sha256','claimed_at','ack_sha256'}
            or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
            or not isinstance(value['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
            or value['phase'] not in ('prepared','claimed','acknowledged')):raise StoreError('bundle_gate/record')
    b=value['binding']
    if (not isinstance(b,dict) or set(b)!={'protocol','bundle_sha256','grant_sha256','device_sha256','owner_sha256','not_before','seconds'}
            or b['protocol']!=PROTOCOL or any(not isinstance(b[k],str) or not HASH.fullmatch(b[k]) for k in
                ('bundle_sha256','grant_sha256','device_sha256','owner_sha256'))
            or not integer(b['not_before'],1,4102444800) or not integer(b['seconds'],5,12)):
        raise StoreError('bundle_gate/record')
    if value['phase']=='prepared':
        if any(value[k] is not None for k in ('request_sha256','claimed_at','ack_sha256')):raise StoreError('bundle_gate/record')
    elif (not isinstance(value['request_sha256'],str) or not HASH.fullmatch(value['request_sha256'])
            or not integer(value['claimed_at'],b['not_before'],4102444800)):
        raise StoreError('bundle_gate/record')
    elif value['phase']=='claimed' and value['ack_sha256'] is not None:
        raise StoreError('bundle_gate/record')
    elif value['phase']=='acknowledged' and (not isinstance(value['ack_sha256'],str) or not HASH.fullmatch(value['ack_sha256'])):
        raise StoreError('bundle_gate/record')
    return value


class DispatchGate:
    """One permanent scope; neither this class nor its callers may reset it."""
    def __init__(self,backend=None,lock=None,*,clock=time.time,zone=local_zone):
        real_scope=backend is None or isinstance(backend,MacKeychain) and backend.service==SERVICE
        if real_scope and (clock is not time.time or zone is not local_zone):raise ValueError('bundle_gate/clock_override')
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-time-bundle-dispatch-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
        self.clock,self.zone=clock,zone

    def _wall_clock(self):
        if isinstance(self.backend,MacKeychain) and self.backend.service==SERVICE and (self.clock is not time.time or self.zone is not local_zone):
            raise ValueError('bundle_gate/clock_override')
        return int(self.clock()),self.zone()

    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            return validate_record(json.loads(raw)),raw
        except Exception:raise StoreError('bundle_gate/record') from None

    def _write(self,value):
        raw=canonical(validate_record(value));self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('bundle_gate/readback')
        self._read();return Receipt(raw)

    def read(self):
        with self.lock():
            value,raw=self._read();return value,Receipt(raw) if raw is not None else None

    def preview(self,bundle,grant,body,guest,config_token):
        # An invalid body must not consume a one-shot scope before any request.
        now,zone=self._wall_clock()
        return verify_request(bundle,grant,body,guest,config_token,now,zone)

    def reserve(self,bundle,grant):
        now,zone=self._wall_clock();bound=binding(bundle,grant,now)
        if zone!='+08:00':raise ValueError('bundle_gate/zone')
        with self.lock():
            if self._read()!=(None,None):raise StoreError('bundle_gate/consumed')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',binding=bound,
                                    request_sha256=None,claimed_at=None,ack_sha256=None))

    def claim(self,receipt,bundle,grant,body,guest,config_token):
        with self.lock():
            value,raw=self._read();now,zone=self._wall_clock()
            if (not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!='prepared'
                    or value['binding']!=binding(bundle,grant,now)):raise StoreError('bundle_gate/changed')
            request_hash=verify_request(bundle,grant,body,guest,config_token,now,zone)
            # Recheck at the durable boundary: validation itself may be slow.
            now,zone=self._wall_clock()
            if verify_request(bundle,grant,body,guest,config_token,now,zone)!=request_hash:
                raise ValueError('bundle_gate/request')
            value.update(phase='claimed',request_sha256=request_hash,claimed_at=now)
            return self._write(value)

    def assert_claim_current(self,receipt,bundle,grant,body,guest,config_token):
        # This is a read-only assertion, not a second permission or retry.
        with self.lock():
            value,raw=self._read();now,zone=self._wall_clock()
            if (not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!='claimed'
                    or value['binding']!=binding(bundle,grant,now)):
                raise StoreError('bundle_gate/changed')
            if verify_request(bundle,grant,body,guest,config_token,now,zone)!=value['request_sha256']:
                raise ValueError('bundle_gate/request')
            return True

    def acknowledge(self,receipt,response):
        if not confirmed(response):raise ValueError('bundle_gate/ack')
        with self.lock():
            value,raw=self._read()
            if not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!='claimed':
                raise StoreError('bundle_gate/changed')
            value.update(phase='acknowledged',ack_sha256=digest(response))
            return self._write(value)
