"""Host-owned private CB native trial broker; the worker command is trusted.

The broker has no HTTP path. A guarded isolated worker must validate its file
before forwarding a claim and recheck it before receiving send approval.
"""
import re,secrets,subprocess
from copy import deepcopy

from cb_native_time_bundle_bridge import Bridge
from cb_native_time_bundle_preflight import Prepared
from cb_native_time_bundle_supervisor import Supervisor
from native_time_bundle_preparation import SigningInputs
from native_trial_pipe import Frames,reply,stop,write_initial
from verify_owner_reading import validate_cookies


def execute(prepared,signing,cookies,store,gate,audit,current,command,*,armed=False):
    """Run one private worker; ambiguous claims are always left consumed."""
    if (not isinstance(prepared,Prepared) or not isinstance(signing,SigningInputs) or type(armed) is not bool
            or not callable(current) or not isinstance(command,list) or not command
            or any(not isinstance(part,str) or not part or '\0' in part for part in command)):
        raise ValueError('cb_broker/input')
    bundle,grant,evidence=prepared.bundle,prepared.grant,prepared.evidence
    if not isinstance(bundle,dict) or not isinstance(grant,dict):raise ValueError('cb_broker/input')
    validate_cookies(cookies,bundle['plan']['owner'])
    if current() is not True or store.read()!=(bundle,prepared.receipt):raise ValueError('cb_broker/stale')
    supervisor=Supervisor(gate,store,bundle,grant,signing.guest,signing.config_token,current,
                          audit_store=audit,evidence=evidence)
    supervisor.prepare();token=secrets.token_hex(16);root='/dev/shm/weread-cb-'+token;source=root+'/source.epub'
    bridge=Bridge(supervisor,source,armed=armed,remote=True)
    _report,_snapshot,months=evidence.for_bundle(bundle,grant)
    payload=dict(bundle=deepcopy(bundle),grant=deepcopy(grant),cookies=deepcopy(cookies),months=deepcopy(months),token=token,armed=armed)
    result=dict(result='UNVERIFIED',account_data_posts_confirmed=0,authentication_posts=0,
                dispatch_may_have_occurred=False,real_accounting_verified=False,profile_removed=False)
    child=pending=None;ready=False;reported=None
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=180,max_frame=3*1024*1024)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':reported=event;break
            pending=event;name=event.get('kind');allowed=False
            if not ready:
                if event!={'kind':'ready','source':source} or current() is not True:raise ValueError('cb_broker/ready')
                ready=True;allowed=True
            else:
                if name not in ('selection','claim','ack'):raise ValueError('cb_broker/order')
                allowed=bridge.handle(event)
            reply(child.stdin,dict(kind=name,ok=allowed));pending=None
        if child.wait(timeout=15)!=0 or not ready or not isinstance(reported,dict):raise ValueError('cb_broker/worker')
        if (set(reported)!={'result','profile_removed','workers_reaped'}
                or reported['profile_removed'] is not True or reported['workers_reaped'] is not True):
            raise ValueError('cb_broker/cleanup')
        if not armed:
            if reported['result']!='DRY_BLOCKED' or bridge.phase!='preview_blocked' or gate.read()!=(None,None) or audit.read()!=(None,None):
                raise ValueError('cb_broker/dry')
            result.update(result='CB_NATIVE_DRY_RUN_VERIFIED',profile_removed=True)
        else:
            if reported['result']!='ACKNOWLEDGED' or bridge.phase!='acknowledged':raise ValueError('cb_broker/unconfirmed')
            result.update(result='CB_NATIVE_ACKNOWLEDGED',account_data_posts_confirmed=1,profile_removed=True)
    except (Exception,KeyboardInterrupt) as error:
        if isinstance(error,ValueError) and re.fullmatch(r'cb_broker/[a-z_]+',str(error)):result['reason']=str(error)
        if child is not None and child.poll() is None and pending is not None:
            try:reply(child.stdin,dict(kind=pending.get('kind'),ok=False))
            except Exception:pass
    finally:
        if child is not None:stop(child)
        for value in (payload.get('grant'),payload.get('cookies')):
            if isinstance(value,dict):value.clear()
        payload.clear()
        try:
            state,_=gate.read()
            result['dispatch_may_have_occurred']=bool(state and state.get('phase') in ('claimed','acknowledged'))
        except Exception:result['dispatch_may_have_occurred']=True
    return result
