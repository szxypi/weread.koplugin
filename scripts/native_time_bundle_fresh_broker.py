"""Host broker for one native time worker; no account HTTP transport here.

The isolated worker and its archive relay are trusted parts of this protocol.
An interrupted or ambiguous durable claim is never replayed.
"""
from copy import deepcopy
from dataclasses import dataclass
import re
import secrets
import subprocess

from native_time_bundle_bridge import NativeTimeBridge
from native_time_bundle_evidence import FreshShelfEvidence
from native_time_bundle_fresh_supervisor import FreshNativeBoundSupervisor
from native_time_bundle_preparation import SigningInputs
from native_trial_pipe import Frames,reply,stop,write_initial
from verify_owner_reading import validate_cookies


@dataclass(repr=False)
class Prepared:
    bundle:dict
    receipt:object
    grant:dict
    evidence:FreshShelfEvidence
    def __repr__(self):return '<NativeFreshPreflight private>'
    def close(self):
        self.bundle.clear();self.grant.clear();self.receipt=None;self.evidence=None


def execute(prepared,signing,cookies,store,gate,audit,current,trial_reader,command,*,armed=False):
    if (not isinstance(prepared,Prepared) or not isinstance(prepared.evidence,FreshShelfEvidence)
            or not isinstance(signing,SigningInputs) or type(armed) is not bool or not callable(current)
            or not callable(trial_reader) or not isinstance(command,list) or not command
            or any(not isinstance(part,str) or not part or '\0' in part for part in command)):
        raise ValueError('fresh_broker/input')
    bundle,grant,evidence=prepared.bundle,prepared.grant,prepared.evidence
    if not isinstance(bundle,dict) or not isinstance(grant,dict):raise ValueError('fresh_broker/input')
    validate_cookies(cookies,bundle['plan']['owner'])
    if current() is not True or store.read()!=(bundle,prepared.receipt):raise ValueError('fresh_broker/stale')
    supervisor=FreshNativeBoundSupervisor(gate,store,bundle,grant,signing.guest,signing.config_token,current,
                                          audit_store=audit,evidence=evidence,trial_reader=trial_reader)
    supervisor.prepare();token=secrets.token_hex(16);root='/dev/shm/weread-native-time-'+token;source=root+'/source.epub'
    bridge=NativeTimeBridge(supervisor,source,armed=armed,remote=True)
    _report,_snapshot,months,_stamp,_shelves,_trial=evidence.for_bundle(bundle,grant)
    payload=dict(bundle=deepcopy(bundle),grant=deepcopy(grant),cookies=deepcopy(cookies),months=deepcopy(months),token=token,armed=armed)
    result=dict(result='UNVERIFIED',account_data_posts_confirmed=0,authentication_posts=0,
                dispatch_may_have_occurred=False,real_accounting_verified=False,profile_removed=False)
    child=pending=None;ready=False;reported=None;denied=False
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=180,max_frame=3*1024*1024)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':reported=event;break
            pending=event;name=event.get('kind');allowed=False
            if not ready:
                if event!={'kind':'ready','source':source} or current() is not True:raise ValueError('fresh_broker/ready')
                ready=True;allowed=True
            else:
                if name not in ('selection','claim','ack'):raise ValueError('fresh_broker/order')
                allowed=bridge.handle(event)
            reply(child.stdin,dict(kind=name,ok=allowed));pending=None
        if child.wait(timeout=15)!=0 or not ready or not isinstance(reported,dict):raise ValueError('fresh_broker/worker')
        if (set(reported)!={'result','profile_removed','workers_reaped'}
                or reported['profile_removed'] is not True or reported['workers_reaped'] is not True):
            raise ValueError('fresh_broker/cleanup')
        if not armed:
            if reported['result']!='DRY_BLOCKED' or bridge.phase!='preview_blocked' or gate.read()!=(None,None) or audit.read()!=(None,None):
                raise ValueError('fresh_broker/dry')
            result.update(result='NATIVE_FRESH_DRY_RUN_VERIFIED',profile_removed=True)
        else:
            if reported['result']!='ACKNOWLEDGED' or bridge.phase!='acknowledged':raise ValueError('fresh_broker/unconfirmed')
            result.update(result='NATIVE_FRESH_ACKNOWLEDGED',account_data_posts_confirmed=1,profile_removed=True)
    except (Exception,KeyboardInterrupt) as error:
        if isinstance(error,ValueError) and re.fullmatch(r'fresh_broker/[a-z_]+',str(error)):result['reason']=str(error)
        if child is not None and child.poll() is None and pending is not None:
            try:reply(child.stdin,dict(kind=pending.get('kind'),ok=False));denied=True
            except Exception:pass
    finally:
        if child is not None:
            if denied:
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:pass
            stop(child)
        for value in (payload.get('grant'),payload.get('cookies')):
            if isinstance(value,dict):value.clear()
        payload.clear()
        try:
            state,_=gate.read()
            result['dispatch_may_have_occurred']=bool(state and state.get('phase') in ('claimed','acknowledged'))
        except Exception:result['dispatch_may_have_occurred']=True
    return result
