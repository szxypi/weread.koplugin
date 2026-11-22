"""Private two-write ReaderUI RPC broker; this module performs no HTTP.

The child is still an isolated test runner, not a production process. The
coordinator owns the durable claim and independent state checks. Restoration is
separate and may begin only after this function succeeds.
"""
import re
import subprocess

from native_trial_pipe import Frames, reply, stop, write_initial


EXPECTED = dict(result='PASS', profile_removed=True, installed_bytes_match=True, native_choice=True,
                actual_source=True, upload_confirmed=True, fresh_process=True, pending_cleared=True,
                journal_cleared=True, automatic_disabled=True, writes=2, denied=0,
                credentials_not_persisted=True, offline_intent=True, reconnect_choice=True)


def execute(command, payload, coordinator, report):
    trial = payload.get('ordinary_trial') if isinstance(payload, dict) else None
    token = trial.get('rpc_token') if isinstance(trial, dict) else None
    if (not isinstance(command, (tuple, list)) or not command or not all(isinstance(v, str) and v for v in command)
            or not isinstance(token, str) or not re.fullmatch(r'[a-f0-9]{32}', token)
            or set(trial) != {'rpc_token'} or payload.get('ordinary') is not True
            or payload.get('armed') is not True or payload.get('reconnect') is not True
            or coordinator.armed is not True or coordinator.index != 0 or coordinator.phase != 'ready'):
        raise ValueError('ordinary_trial/broker_scope')
    child = None
    claimed = acknowledged = verified = 0
    report.update(result='UNVERIFIED', claimed_posts=0, acknowledged_posts=0, independently_verified=0,
                  claim_interrupted=False)
    try:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        write_initial(child.stdin, payload)
        frames = Frames(child.stdout, token, timeout=420)
        while True:
            kind, value = frames.next()
            if kind == 'RESULT':
                if value != EXPECTED or claimed != 2 or acknowledged != 2 or verified != 2:
                    raise ValueError('ordinary_trial/reader_result')
                break
            event, seq = value.get('kind'), value.get('seq')
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
