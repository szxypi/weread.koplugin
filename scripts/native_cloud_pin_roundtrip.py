"""Bounded owner trial: host add/remove, native pin/unpin, independent gates."""
from copy import deepcopy
import secrets
import subprocess
from native_cloud_pin_trial import bind,check as check_native
from native_trial_pipe import Frames,reply,stop,write_initial
from pin_trial_contract import verify
from verify_finish_roundtrip import acknowledged
from verify_native_finish_trial import validate_result
from verify_pin_preflight import fingerprint,progress_fingerprint,reading_fingerprint


class RoundtripFailure(ValueError):
    def __init__(self,phase,steps,runner=None):
        super().__init__('native_cloud_pin/unverified');self.phase=phase;self.steps=steps;self.runner=runner


def stable(plans,reading_sha,current,read,present,*,target_flags=None,pin=None,native_plan=None,strict_pin_baseline=False):
    observations=[];last=None
    for _ in range(2):
        current();sources,progress=read()
        if set(sources)!={'native','web','gateway'} or reading_fingerprint(progress)!=reading_sha:
            raise ValueError('native_cloud_pin/reading_changed')
        rows=verify(sources,plans,present)
        if present:
            for row in rows.values():
                if pin=='unset' and row['pinned'] not in ({'reason':'missing'},{'value':False}):raise ValueError('native_cloud_pin/target_pinned')
                if pin=='set' and row['pinned']!={'value':True}:raise ValueError('native_cloud_pin/pin_unobserved')
            if target_flags is not None:
                for name in rows:
                    for field in ('private','finished'):
                        if rows[name][field]!=target_flags[name][field]:raise ValueError('native_cloud_pin/target_changed')
                    if strict_pin_baseline and rows[name]['pinned']!=target_flags[name]['pinned']:
                        raise ValueError('native_cloud_pin/target_changed')
            if native_plan is not None:check_native(native_plan,sources['native'],progress,pin=='set')
        observations.append(rows);last=(sources,progress,rows)
    if observations[0]!=observations[1]:raise ValueError('native_cloud_pin/unstable')
    return last


def native_child(payload,command,*,armed,on_step):
    if not command or '--armed' in command or any(not isinstance(value,str) or not value for value in command):raise ValueError('native_cloud_pin/command')
    bound=deepcopy(payload);bound.update(permit_writes=armed,rpc_token=secrets.token_hex(16))
    child=None;runner=None;steps=0;awaiting=None
    try:
        child=subprocess.Popen(command+(['--armed'] if armed else []),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,bound);frames=Frames(child.stdout,bound['rpc_token'],timeout=300)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':runner=validate_result(value,armed);break
            awaiting=value.get('seq')
            if (not armed or set(value)!={'seq'} or type(awaiting) is not int
                    or awaiting!=steps+1 or steps>=2):raise ValueError('native_cloud_pin/step')
            on_step(awaiting);steps=awaiting;reply(child.stdin,dict(seq=steps,ok=True));awaiting=None
        if (child.wait(timeout=15) or runner['result']!='PASS' or steps!=(2 if armed else 0)
                or runner['stage']['shelf_books']!=bound['shelf_books']):raise ValueError('native_cloud_pin/child')
        return runner,steps
    except (Exception,KeyboardInterrupt) as error:
        if child is not None and child.poll() is None and awaiting is not None:
            try:reply(child.stdin,dict(seq=awaiting,ok=False))
            except Exception:pass
        raise RoundtripFailure('native',steps,runner) from error
    finally:
        if child is not None:stop(child)
        bound.clear()


def run(plans,reading_sha,skill_sha,outer,inner,current,read,send,command,credentials,metadata,*,mock_port=None):
    """Consume one new intent. A failure retains the exact last durable phase."""
    if outer.read()[0] is not None or inner.read()[0] is not None:raise ValueError('native_cloud_pin/already_used')
    membership=plans['native']['membership'];identity=membership['book_id']
    if (membership['owner']!=credentials.get('vid') or membership['grant_sha256']!=fingerprint(credentials)
            or not isinstance(metadata,dict) or metadata.get('bookId')!=identity):raise ValueError('native_cloud_pin/scope')
    _sources,before,_=stable(plans,reading_sha,current,read,False);full_before=progress_fingerprint(before)
    _state,raw=outer.reserve(deepcopy(plans),reading_sha,skill_sha);phase='prepared';steps=0;runner=None
    try:
        stable(plans,reading_sha,current,read,False)
        _state,raw=outer.advance(raw,'add_pending');phase='add_pending'
        if not acknowledged(send('add')):raise ValueError('native_cloud_pin/add_receipt')
        _state,raw=outer.advance(raw,'add_acknowledged');phase='add_acknowledged'
        sources,progress,target=stable(plans,reading_sha,current,read,True,pin='unset')
        target=deepcopy(target)
        native_plan=bind(membership['owner'],identity,membership['grant_sha256'],sources['native'],progress)
        _state,raw=outer.advance(raw,'add_verified');phase='add_verified'
        payload=dict(credentials=credentials,book_id=identity,expected_metadata=metadata,
                     shelf_books=len(sources['native']['books']),mark=deepcopy(native_plan['mark']),restore=deepcopy(native_plan['restore']))
        if mock_port is not None:
            if (type(mock_port) is not int or not 1<=mock_port<=65535 or identity!='900001'
                    or credentials!=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',
                                        deviceId='eink334691225'+'1'*19)):raise ValueError('native_cloud_pin/mock')
            payload['mock_port']=mock_port
        dry,_=native_child(payload,command,armed=False,on_step=lambda _step:None)
        stable(plans,reading_sha,current,read,True,target_flags=target,pin='unset',strict_pin_baseline=True)
        inner_receipt=inner.reserve(native_plan)
        _state,raw=outer.advance(raw,'pin_pending');phase='pin_pending'
        def on_step(sequence):
            nonlocal raw,phase,steps
            if not inner.owns(inner_receipt,native_plan):raise ValueError('native_cloud_pin/intent_changed')
            if sequence==1:
                stable(plans,reading_sha,current,read,True,target_flags=target,pin='set',native_plan=native_plan)
                _state,raw=outer.advance(raw,'pin_checked');phase='pin_checked'
                _state,raw=outer.advance(raw,'unpin_pending');phase='unpin_pending'
            elif sequence==2:
                stable(plans,reading_sha,current,read,True,target_flags=target,pin='unset',native_plan=native_plan)
                _state,raw=outer.advance(raw,'unpin_checked');phase='unpin_checked'
            else:raise ValueError('native_cloud_pin/step')
            steps=sequence
        runner,child_steps=native_child(payload,command,armed=True,on_step=on_step)
        if child_steps!=2 or steps!=2:raise ValueError('native_cloud_pin/step')
        stable(plans,reading_sha,current,read,True,target_flags=target,pin='unset',native_plan=native_plan)
        _state,raw=outer.advance(raw,'remove_pending');phase='remove_pending'
        if not acknowledged(send('remove')):raise ValueError('native_cloud_pin/remove_receipt')
        _sources,after,_=stable(plans,reading_sha,current,read,False)
        inner.finish(inner_receipt,restored_verified=True)
        _state,raw=outer.advance(raw,'restored');phase='restored'
        return dict(result='OWNER_NATIVE_PIN_ROUNDTRIP_VERIFIED',host_data_posts=2,native_data_posts=2,independent_steps=steps,
                    original_shelf_and_reading_fields_verified=True,book_update_time_unchanged=progress_fingerprint(after)==full_before,
                    progress_projection='exclude_server_clock_and_book_update_time',dry_run=dry,native_ui=runner,
                    outer_intent_state=phase,inner_intent_state='retired',no_automatic_replay=True)
    except RoundtripFailure as error:
        raise RoundtripFailure(phase,steps,error.runner) from None
    except (Exception,KeyboardInterrupt):
        raise RoundtripFailure(phase,steps,runner) from None
