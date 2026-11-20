"""Private worker broker for the independent capture and its own journals.

For a real Keychain session only the attested local KOReader worker is accepted.
An unconfirmed durable claim is never retried. Readback is a separate step.
"""
from copy import deepcopy
from dataclasses import dataclass
import re
import secrets
import subprocess

from native_time_bundle_bridge import NativeTimeBridge
from native_time_bundle_evidence import IndependentCaptureEvidence
from native_time_bundle_preparation import SigningInputs
from native_time_capture_fresh_bundle import SERVICE as CAPTURE_SERVICE
from native_time_independent_audit import IndependentAudit,SERVICE as AUDIT_SERVICE
from native_time_independent_gate import IndependentGate,SERVICE as GATE_SERVICE
from native_time_independent_supervisor import IndependentNativeBoundSupervisor
from native_trial_pipe import Frames,reply,stop,write_initial
from secure_native_session import NativeSessionStore
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_native_time_fresh_dry import trusted_command
from verify_owner_reading import validate_cookies


class AccountBinding:
    """Snapshot the two project sessions without exposing either in reports."""
    def __init__(self,session,native):
        if type(session) is not SessionStore or type(native) is not NativeSessionStore:
            raise ValueError('independent_broker/session')
        self.session,self.native=session,native
        self._saved=session.load();self._grant=native.load(self._saved['vid'])
        if self._grant['vid']!=self._saved['vid']:raise ValueError('independent_broker/session')

    def __call__(self):
        return self.session.load()==self._saved and self.native.load(self._saved['vid'])==self._grant

    def matches(self,grant,cookies):
        return self() and grant==self._grant and cookies==self._saved['cookies']

    def close(self):
        self._saved.clear();self._grant.clear()

    def __repr__(self):return '<AccountBinding private>'


@dataclass(repr=False)
class Prepared:
    bundle:dict
    receipt:object
    grant:dict
    evidence:IndependentCaptureEvidence
    def __repr__(self):return '<IndependentNativePreflight private>'
    def close(self):
        self.bundle.clear();self.grant.clear();self.receipt=None;self.evidence=None


def ui_command_from(command):
    """Derive the single fixed-size dry-only menu worker from the attested task."""
    old='scripts/run_native_time_guarded_worker.py'
    if not isinstance(command,list) or command.count(old)!=1:raise ValueError('independent_broker/command')
    result=list(command);result[result.index(old)]='scripts/run_native_time_independent_ui_worker.py'
    return result+['--width','1264','--height','1680','--dpi','300']


def execute(prepared,signing,cookies,store,gate,audit,current,command,*,armed=False):
    if (not isinstance(prepared,Prepared) or not isinstance(prepared.evidence,IndependentCaptureEvidence)
            or not isinstance(signing,SigningInputs) or not isinstance(gate,IndependentGate)
            or not isinstance(audit,IndependentAudit) or type(armed) is not bool or not callable(current)
            or not isinstance(command,list) or not command
            or any(not isinstance(part,str) or not part or '\0' in part for part in command)):
        raise ValueError('independent_broker/input')
    bundle,grant,evidence=prepared.bundle,prepared.grant,prepared.evidence
    if not isinstance(bundle,dict) or not isinstance(grant,dict):raise ValueError('independent_broker/input')
    validate_cookies(cookies,bundle['plan']['owner'])
    real=isinstance(getattr(store,'backend',None),MacKeychain) or gate._real or audit._real
    if real:
        if (not isinstance(getattr(store,'backend',None),MacKeychain) or store.backend.service!=CAPTURE_SERVICE
                or store.backend.account!=ACCOUNT or not gate._real or not audit._real
                or not isinstance(gate.backend,MacKeychain) or gate.backend.service!=GATE_SERVICE
                or not isinstance(audit.backend,MacKeychain) or audit.backend.service!=AUDIT_SERVICE
                or type(current) is not AccountBinding
                or not current.matches(grant,cookies)):
            raise ValueError('independent_broker/scope')
        attested=trusted_command()
        allowed=[attested+['--allow-live']] if armed else [attested,ui_command_from(attested)]
        if command not in allowed:raise ValueError('independent_broker/command')
    if current() is not True or store.read()!=(bundle,prepared.receipt):raise ValueError('independent_broker/stale')
    supervisor=IndependentNativeBoundSupervisor(gate,store,bundle,grant,signing.guest,signing.config_token,current,
                                                audit_store=audit,evidence=evidence)
    supervisor.prepare();token=secrets.token_hex(16);root='/dev/shm/weread-native-time-'+token;source=root+'/source.epub'
    bridge=NativeTimeBridge(supervisor,source,armed=armed,remote=True)
    _report,_snapshot,months,_stamp,_shelves,_components=evidence.for_bundle(bundle,grant)
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
                if event!={'kind':'ready','source':source} or current() is not True:raise ValueError('independent_broker/ready')
                ready=True;allowed=True
            else:
                if name not in ('selection','claim','ack'):raise ValueError('independent_broker/order')
                allowed=bridge.handle(event)
            reply(child.stdin,dict(kind=name,ok=allowed));pending=None
        if child.wait(timeout=15)!=0 or not ready or not isinstance(reported,dict):raise ValueError('independent_broker/worker')
        if (set(reported)!={'result','profile_removed','workers_reaped'}
                or reported['profile_removed'] is not True or reported['workers_reaped'] is not True):
            raise ValueError('independent_broker/cleanup')
        if not armed:
            if reported['result']!='DRY_BLOCKED' or bridge.phase!='preview_blocked' or gate.read()!=(None,None) or audit.read()!=(None,None):
                raise ValueError('independent_broker/dry')
            result.update(result='INDEPENDENT_NATIVE_DRY_RUN_VERIFIED',profile_removed=True)
        else:
            if reported['result']!='ACKNOWLEDGED' or bridge.phase!='acknowledged':raise ValueError('independent_broker/unconfirmed')
            result.update(result='INDEPENDENT_NATIVE_ACKNOWLEDGED',account_data_posts_confirmed=1,profile_removed=True)
    except (Exception,KeyboardInterrupt) as error:
        if isinstance(error,ValueError) and re.fullmatch(r'independent_broker/[a-z_]+',str(error)):result['reason']=str(error)
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
