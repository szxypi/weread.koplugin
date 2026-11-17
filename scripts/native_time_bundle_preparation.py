"""Read-only, bounded signing-input preparation after a fresh bundle preflight.

No send/renewal/journal-write method is provided. Secret inputs remain in
memory and do not authorize dispatch; a later supervisor repeats live checks.
"""
from copy import deepcopy
from dataclasses import dataclass
import time

from native_time_bundle_gate import binding
from readtime_upload_model import guest_token,integer
from secure_weread_session import MacKeychain
from native_time_capture_bundle import SERVICE as CAPTURE_SERVICE
from verify_eink_login import BASE,NativeProbe
from verify_eink_renewal import validate_credentials


@dataclass(frozen=True,repr=False)
class SigningInputs:
    guest: str
    config_token: str

    def __post_init__(self):
        if any(not isinstance(v,str) or not 1<=len(v.encode())<=4096 for v in (self.guest,self.config_token)):
            raise ValueError('bundle_preparation/input')


class SigningRead(NativeProbe):
    def __init__(self,grant,current,opener=None):
        super().__init__(opener);validate_credentials(grant)
        self.grant=deepcopy(grant);self.current=current;self.stages=[]

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed=[('bundle_config',BASE+'/config?token=1'),('bundle_feature',BASE+'/feature?synckey=0')]
        if (len(self.stages)>=2 or (stage,url)!=allowed[len(self.stages)] or body is not None
                or credentials!=self.grant or self.current() is not True):
            raise ValueError('bundle_preparation/read_scope')
        self.stages.append(stage)
        value=super().request(stage,url,credentials=credentials,timeout=timeout)
        if self.current() is not True:raise ValueError('bundle_preparation/session')
        return value

    def read(self):
        if self.stages:raise ValueError('bundle_preparation/reused')
        config=self.request('bundle_config',BASE+'/config?token=1',credentials=self.grant)
        token=config.get('token')
        if not isinstance(token,str) or not 1<=len(token.encode())<=4096:raise ValueError('bundle_preparation/config')
        feature=self.request('bundle_feature',BASE+'/feature?synckey=0',credentials=self.grant)
        guest,_kind=guest_token(feature)
        return SigningInputs(guest=guest,config_token=token)


def read_signing_inputs(*,bundle,receipt,grant,store,gate,current,preflight,probe,clock=time.time):
    if isinstance(getattr(store,'backend',None),MacKeychain) and store.backend.service==CAPTURE_SERVICE and clock is not time.time:
        raise ValueError('bundle_preparation/clock_override')
    if not callable(clock) or not callable(current):raise ValueError('bundle_preparation/input')
    def fresh():
        return current() is True and store.read()==(bundle,receipt) and gate.read()==(None,None)
    if receipt is None or not fresh():raise ValueError('bundle_preparation/stale')
    now=int(clock());binding(bundle,grant,now)
    flags=('exact_capture_and_fixture_bound','fixture_in_captured_baseline',
           'both_positions_source_counts_and_original_shelf_exact','two_statistics_reads_stable','server_clock_after_boundary')
    if (not isinstance(preflight,dict) or preflight.get('result')!='CROSS_DAY_READONLY_VERIFIED'
            or any(preflight.get(key) is not True for key in flags)
            or type(preflight.get('seconds')) is not int or preflight['seconds']!=bundle['plan']['seconds']
            or not integer(preflight.get('completed_at'),bundle['plan']['not_before'],4102444800)
            or not 0<=now-preflight['completed_at']<30
            or any(type(preflight.get(k)) is not int or preflight[k]!=0 for k in ('account_data_posts','authentication_posts'))
            or preflight.get('historical_accounting_verified') is not False or preflight.get('dispatch_capability') is not False):
        raise ValueError('bundle_preparation/preflight')
    if not fresh():raise ValueError('bundle_preparation/stale')
    inputs=probe.read()
    if not isinstance(inputs,SigningInputs) or not fresh():raise ValueError('bundle_preparation/stale')
    final=int(clock());binding(bundle,grant,final)
    if not 0<=final-preflight['completed_at']<30:raise ValueError('bundle_preparation/preflight_expired')
    return inputs
