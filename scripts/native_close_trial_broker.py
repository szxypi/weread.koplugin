"""Host-owned independent ReaderUI plan/claim/ACK broker. No HTTP write path."""
from copy import deepcopy
import re
import subprocess
import time
from native_trial_pipe import Frames,write_initial,reply,stop
from native_close_trial_contract import validate_payload,validate_result
from secure_native_close_trial import validate_plan
from secure_native_txt_roundtrip import point,POINT_FIELDS
from native_txt_read_model import body
from verify_native_position_lua import equivalent


def check_metadata(metadata,plan,shelf_hash,reader_percent,bind_percent):
    fields={'book_id','before','desired','counts','version','shelf_sha256','source_sha256','file_id','basis'}
    if not isinstance(metadata,dict) or set(metadata)!=fields:raise ValueError('close_trial/metadata')
    point(metadata['before']);point(metadata['desired'])
    if (metadata['basis']!='raw_txt_utf16' or metadata['book_id']!=plan['baseline']['book_id']
            or not equivalent(metadata['before'],plan['baseline']) or not equivalent(metadata['counts'],plan['counts'])
            or type(metadata['version']) is not int or metadata['version']!=plan['version']
            or metadata['source_sha256']!=plan['source_sha256'] or metadata['shelf_sha256']!=shelf_hash
            or not isinstance(metadata['file_id'],str) or not re.fullmatch('[a-f0-9]{64}',metadata['file_id'])
            or type(reader_percent) is not int or not 0<=reader_percent<=100
            or metadata['desired']['raw_percent']!=reader_percent
            or any(metadata['desired'][k]!=plan['target'][k] for k in POINT_FIELDS-{'raw_percent'})
            or bind_percent and metadata['desired']['raw_percent']!=plan['target']['raw_percent']):
        raise ValueError('close_trial/metadata')
    selected=deepcopy(plan);selected['target']['raw_percent']=reader_percent;validate_plan(selected);return selected


def execute(payload,command,store,report,*,prepare=False,current=None,before=None,after=None):
    trial=payload['native_close_trial'];armed=trial['armed'];plan=deepcopy(trial['plan'])
    validate_payload(payload,armed,payload.get('reader_mock_port'))
    state,receipt=store.read()
    if (type(prepare) is not bool or armed and prepare or trial['bind_percent'] is prepare
            or prepare and state is not None or not prepare and (not state or state['phase']!='prepared' or state['plan']!=plan)):
        raise ValueError('close_trial/intent')
    child=awaiting=runner=None;planned=body_steps=ack_steps=verified_steps=0
    report.update(account_data_posts=0,planned=0,body_checks=0,explicit_success_receipts=0,independent_steps=0)
    try:
        if current:current()
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,trial['rpc_token'],timeout=420)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':
                runner=validate_result(value,armed,payload['vid'])
                report['native_ui']={k:v for k,v in runner.items() if k!='cookies'};break
            awaiting=value;event=value.get('kind');seq=value.get('seq')
            if type(seq) is not int or not 1<=seq<=2:raise ValueError('close_trial/sequence')
            if event=='plan':
                if planned or seq!=1 or set(value)!={'kind','seq','metadata','reader_percent'}:raise ValueError('close_trial/plan_sequence')
                selected=check_metadata(value['metadata'],plan,trial['native_shelf_sha256'],value['reader_percent'],trial['bind_percent'])
                if not prepare and selected!=state['plan']:raise ValueError('close_trial/plan_changed')
                plan=selected;trial['plan']=deepcopy(plan);planned=1
            elif event in ('claim','dry_body'):
                if (not planned or set(value)!={'kind','seq','body'} or seq!=verified_steps+1 or body_steps!=verified_steps
                        or event!=('claim' if armed else 'dry_body') or not armed and seq!=1):raise ValueError('close_trial/body_sequence')
                candidate=value['body']
                if not isinstance(candidate,dict):raise ValueError('close_trial/body')
                stamp,random=candidate.get('timestamp'),candidate.get('random')
                if (type(stamp) is not int or not 0<=time.time()-stamp<=30 or type(random) is not int or not 0<=random<=999):raise ValueError('close_trial/clock')
                expected=body(payload['native_grant'],plan['target' if seq==1 else 'baseline'],plan['version'],trial['guest'],stamp,random,trial['time_zone'])
                if not equivalent(expected,candidate):raise ValueError('close_trial/body')
                if current:current()
                if before:before(seq,plan)
                if armed:
                    receipt=store.advance(receipt,'prepared' if seq==1 else 'advance_verified','advance_pending' if seq==1 else 'restore_pending')
                body_steps=seq
            elif event=='ack':
                if (not armed or set(value)!={'kind','seq'} or seq!=body_steps or seq!=ack_steps+1):raise ValueError('close_trial/ack_sequence')
                receipt=store.advance(receipt,'advance_pending' if seq==1 else 'restore_pending','advance_acknowledged' if seq==1 else 'restore_acknowledged');ack_steps=seq
            elif event=='verified':
                if (not armed or set(value)!={'kind','seq'} or seq!=ack_steps or seq!=verified_steps+1):raise ValueError('close_trial/verified_sequence')
                if current:current()
                if after:after(seq,plan)
                receipt=store.advance(receipt,'advance_acknowledged' if seq==1 else 'restore_acknowledged','advance_verified' if seq==1 else 'retired');verified_steps=seq
            else:raise ValueError('close_trial/event')
            reply(child.stdin,dict(kind=event,seq=seq,ok=True));awaiting=None
        if child.wait(timeout=15) or runner['result']!='PASS' or verified_steps!=(2 if armed else 0) or body_steps!=(2 if armed else 1):raise ValueError('close_trial/native_failed')
        if prepare:
            if current:current()
            store.reserve(plan)
        report.update(result='NATIVE_CLOSE_TRIAL_PREPARED' if prepare else 'NATIVE_CLOSE_TRIAL_VERIFIED' if armed else 'NATIVE_CLOSE_TRIAL_DISARMED_VERIFIED',
                      original_restoration_verified=armed,synthetic_only='reader_mock_port' in payload,no_automatic_replay=True)
        return runner['cookies']
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and re.fullmatch('close_trial/[a-z_]+',str(error)):report['reason']=str(error)
        if child is not None and child.poll() is None and awaiting is not None:
            try:reply(child.stdin,dict(kind=awaiting.get('kind'),seq=awaiting.get('seq'),ok=False))
            except Exception:pass
        raise
    finally:
        report.update(planned=planned,body_checks=body_steps,explicit_success_receipts=ack_steps,independent_steps=verified_steps,
                      account_data_posts=body_steps if armed and 'reader_mock_port' not in payload else 0,
                      synthetic_posts=body_steps if armed and 'reader_mock_port' in payload else 0)
        if child is not None:stop(child)
