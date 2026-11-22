"""Private two-write ReaderUI RPC broker; this module performs no HTTP.

The child is still an isolated test runner, not a production process. The
coordinator owns the durable claim and independent state checks. Restoration is
separate and may begin only after this function succeeds.
"""
import re
import subprocess

from native_trial_pipe import Frames, MAX_INPUT, reply, stop, write_initial


EXPECTED = dict(result='PASS', profile_removed=True, installed_bytes_match=True, native_choice=True,
                actual_source=True, upload_confirmed=True, fresh_process=True, pending_cleared=True,
                journal_cleared=True, automatic_disabled=True, writes=2, denied=0,
                credentials_not_persisted=True, offline_intent=True, reconnect_choice=True)
DRY_EXPECTED = dict(result='DRY_RUN', profile_removed=True, installed_bytes_match=True, native_choice=True,
                    write_blocked=True, writes=0, denied=1, credentials_not_persisted=True,
                    offline_intent=True, reconnect_choice=True)


def preview(command, payload, check_body, report, *, check_context=None):
    """Bind a proposed body in memory; the child must independently deny it."""
    trial = payload.get('ordinary_trial') if isinstance(payload, dict) else None
    token = trial.get('rpc_token') if isinstance(trial, dict) else None
    if (not isinstance(command, (tuple, list)) or not command or not all(isinstance(v, str) and v for v in command)
            or not isinstance(token, str) or not re.fullmatch(r'[a-f0-9]{32}', token)
            or set(trial) != {'rpc_token'} or payload.get('ordinary') is not True
            or payload.get('armed') is not False or payload.get('reconnect') is not True or not callable(check_body)):
        raise ValueError('ordinary_trial/broker_scope')
    if check_context is not None and not callable(check_context):raise ValueError('ordinary_trial/broker_scope')
    child = None; checked = False; contexts = 0
    report.update(result='UNVERIFIED', body_checked=False, contexts_checked=0)
    try:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        write_initial(child.stdin, payload); frames = Frames(child.stdout, token, timeout=420, max_frame=MAX_INPUT)
        while True:
            kind, value = frames.next()
            if kind == 'RESULT':
                if value != DRY_EXPECTED or not checked or check_context is not None and contexts==0: raise ValueError('ordinary_trial/reader_result')
                break
            if value.get('kind') == 'reader_context':
                if (checked or check_context is None or contexts>=8 or set(value)!={'kind','seq','html'}
                        or type(value['seq']) is not int or value['seq']!=0 or not isinstance(value['html'],str)
                        or len(value['html'].encode('utf-8'))>4*1024*1024 or check_context(value['html']) is not True):
                    raise ValueError('ordinary_trial/context')
                contexts+=1;report['contexts_checked']=contexts
                reply(child.stdin,dict(kind='reader_context',seq=0,ok=True));continue
            if (checked or set(value) != {'kind', 'seq', 'body'} or value['kind'] != 'dry_body'
                    or type(value['seq']) is not int or value['seq'] != 1):
                raise ValueError('ordinary_trial/sequence')
            if check_body(value['body']) is not True: raise ValueError('ordinary_trial/body')
            checked = True; reply(child.stdin, dict(kind='dry_body', seq=1, ok=True))
        if child.wait(timeout=15): raise ValueError('ordinary_trial/reader_result')
        report.update(result='READER_POSITION_DRY_VERIFIED', body_checked=True)
    finally:
        if child is not None: stop(child)


def execute(command, payload, coordinator, report, *, check_context=None):
    trial = payload.get('ordinary_trial') if isinstance(payload, dict) else None
    token = trial.get('rpc_token') if isinstance(trial, dict) else None
    if (not isinstance(command, (tuple, list)) or not command or not all(isinstance(v, str) and v for v in command)
            or not isinstance(token, str) or not re.fullmatch(r'[a-f0-9]{32}', token)
            or set(trial) != {'rpc_token'} or payload.get('ordinary') is not True
            or payload.get('armed') is not True or payload.get('reconnect') is not True
            or coordinator.armed is not True or coordinator.index != 0 or coordinator.phase != 'ready'):
        raise ValueError('ordinary_trial/broker_scope')
    if check_context is not None and not callable(check_context):raise ValueError('ordinary_trial/broker_scope')
    child = None; contexts = 0
    claimed = acknowledged = verified = 0
    report.update(result='UNVERIFIED', claimed_posts=0, acknowledged_posts=0, independently_verified=0,
                  claim_interrupted=False, contexts_checked=0)
    try:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        write_initial(child.stdin, payload)
        frames = Frames(child.stdout, token, timeout=420, max_frame=MAX_INPUT)
        while True:
            kind, value = frames.next()
            if kind == 'RESULT':
                if value != EXPECTED or claimed != 2 or acknowledged != 2 or verified != 2 or check_context is not None and contexts==0:
                    raise ValueError('ordinary_trial/reader_result')
                break
            event, seq = value.get('kind'), value.get('seq')
            if event == 'reader_context':
                if (claimed or check_context is None or contexts>=8 or set(value)!={'kind','seq','html'}
                        or type(seq) is not int or seq!=0 or not isinstance(value['html'],str)
                        or len(value['html'].encode('utf-8'))>4*1024*1024):raise ValueError('ordinary_trial/context')
                binding=check_context(value['html'])
                if not isinstance(binding,dict) or set(binding)!={'context','pclts'}:raise ValueError('ordinary_trial/context')
                coordinator.bind_context(binding['context'],binding['pclts']);contexts+=1;report['contexts_checked']=contexts
                reply(child.stdin,dict(kind='reader_context',seq=0,ok=True));continue
            if type(seq) is not int or seq not in (1, 2):
                raise ValueError('ordinary_trial/sequence')
            stage = ('enter', 'position')[seq-1]
            if event == 'claim':
                if set(value) != {'kind', 'seq', 'body'} or seq != verified + 1 or claimed != verified:
                    raise ValueError('ordinary_trial/sequence')
                report['claim_interrupted'] = True
                if coordinator.claim(stage, value['body']) is not True:
                    raise ValueError('ordinary_trial/blocked')
                claimed += 1
                report['claim_interrupted'] = False
            elif event == 'ack':
                if set(value) != {'kind', 'seq', 'status', 'response'} or seq != claimed or acknowledged != seq-1:
                    raise ValueError('ordinary_trial/sequence')
                coordinator.ack(stage, value['status'], value['response']); acknowledged += 1
                coordinator.verify(stage); verified += 1
            else:
                raise ValueError('ordinary_trial/sequence')
            reply(child.stdin, dict(kind=event, seq=seq, ok=True))
        if child.wait(timeout=15) or coordinator.phase != 'ready' or coordinator.index != 2:
            raise ValueError('ordinary_trial/reader_result')
        report['result'] = 'READER_POSITION_VERIFIED_RESTORE_PENDING'
    except BaseException:
        coordinator.phase = 'stopped'
        raise
    finally:
        report.update(claimed_posts=claimed, acknowledged_posts=acknowledged, independently_verified=verified)
        if child is not None:
            stop(child)
