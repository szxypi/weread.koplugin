"""Host-owned two-step supervision of a native chapter ReaderUI trial.

No HTTP write path lives here. Private frames and the recovery plan never go
to stdout; each claim is persisted before the UI worker may send its POST.
"""
from copy import deepcopy
from hashlib import sha256
import re
import subprocess
import time

from native_trial_pipe import Frames,reply,stop,write_initial
from native_txt_read_model import body
from secure_native_txt_roundtrip import POINT_FIELDS,validate_binding
from secure_weread_session import StoreError
from txt_coordinates import PlainSource
from verify_native_direct_position_owner import independent_offset
from verify_native_position_lua import equivalent
from verify_source_coordinates import FilteredSource

PROTOCOL='native-direct-ui-xhtml-zero-time-v1'
TXT_PROTOCOL='native-direct-ui-txt-zero-time-v1'


def validate_plan(plan,protocol=PROTOCOL):
    validate_binding(plan,protocol)
    if (any(plan['baseline'][key]!=plan['target'][key] for key in POINT_FIELDS-{'chapter_offset','summary'})
            or plan['target']['chapter_offset']==plan['baseline']['chapter_offset'] or plan['chapter_progress'] is not None
            or protocol==TXT_PROTOCOL and plan['version']!=0):
        raise StoreError('direct_ui_trial/plan')


def bind_metadata(metadata,anchor,plan,raw):
    fields={'book_id','before','desired','counts','version','shelf_sha256','source_sha256','file_id','basis'}
    if not isinstance(metadata,dict) or set(metadata)!=fields or not isinstance(anchor,dict) \
            or set(anchor)!={'text','point_offset'}:
        raise ValueError('direct_ui_trial/metadata')
    desired=metadata['desired']
    txt=plan['protocol']==TXT_PROTOCOL
    expected_basis='raw_txt_utf16' if txt else 'filtered_xhtml_utf16'
    if (metadata['basis']!=expected_basis or metadata['book_id']!=plan['baseline']['book_id']
            or metadata['before']!=plan['baseline'] or metadata['counts']!=plan['counts']
            or metadata['version']!=plan['version'] or metadata['source_sha256']!=plan['source_sha256']
            or metadata['shelf_sha256']!=plan['shelf_sha256'] or not isinstance(metadata['file_id'],str)
            or not re.fullmatch('[a-f0-9]{64}',metadata['file_id']) or not isinstance(desired,dict)):
        raise ValueError('direct_ui_trial/metadata')
    point={'ok':True,'text':anchor['text'],'point_offset':anchor['point_offset'],'offset':desired.get('chapter_offset')}
    if not independent_offset(raw,point,plain_text=txt):raise ValueError('direct_ui_trial/source')
    if txt:
        if sha256(raw).hexdigest()!=plan['source_sha256']:raise ValueError('direct_ui_trial/source')
        summary=PlainSource(raw.decode('utf-8')).excerpt(desired['chapter_offset'])['text']
    else:
        model=FilteredSource(raw.decode('utf-8'),allow_multiple_bodies=True)
        visible=[index for index,char in enumerate(model.characters) if not char.isspace()]
        positions=[i for i,index in enumerate(visible) if model.starts[index]==desired['chapter_offset']]
        if len(positions)!=1:raise ValueError('direct_ui_trial/source')
        index=positions[0];summary=''.join(model.characters[i] for i in visible[index:index+20])
    if not summary or desired.get('summary')!=summary:raise ValueError('direct_ui_trial/summary')
    selected=deepcopy(plan);selected['target']=deepcopy(desired);validate_plan(selected,TXT_PROTOCOL if txt else PROTOCOL)
    return selected


def execute(payload,command,store,raw,report,*,current,before,after):
    trial=payload['trial'];armed=trial['armed'];plan=deepcopy(trial['plan'])
    if type(armed) is not bool or not isinstance(command,list) or not command or store.read()[0] is not None:
        raise ValueError('direct_ui_trial/intent')
    child=receipt=waiting=None;planned=claimed=acknowledged=verified=0
    try:
        current()
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,trial['rpc_token'],timeout=420)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':
                runner=value
                if runner.get('result')!='PASS':
                    if runner.get('phase') in ('input','prepare','reader','audit'):report['runner_phase']=runner['phase']
                    if type(runner.get('probe_line')) is int:report['probe_line']=runner['probe_line']
                    if runner.get('outcome') in ('confirmed','unconfirmed','unavailable','login','noop'):report['outcome']=runner['outcome']
                    if type(runner.get('readbacks')) is int:report['readbacks']=runner['readbacks']
                    if isinstance(runner.get('diagnostic'),str) and re.fullmatch('[a-z_]{1,40}',runner['diagnostic']):report['diagnostic']=runner['diagnostic']
                break
            waiting=value;event=value.get('kind');seq=value.get('seq')
            if type(seq) is not int or seq not in (1,2):raise ValueError('direct_ui_trial/sequence')
            if event=='plan':
                if planned or seq!=1 or set(value)!={'kind','seq','metadata','anchor'}:raise ValueError('direct_ui_trial/sequence')
                plan=bind_metadata(value['metadata'],value['anchor'],plan,raw);planned=1
                if armed:
                    current();before(1,plan);receipt=store.reserve(plan)
            elif event in ('claim','dry_body'):
                if (not planned or set(value)!={'kind','seq','body'} or seq!=verified+1 or claimed!=verified
                        or event!=('claim' if armed else 'dry_body') or not armed and seq!=1):
                    raise ValueError('direct_ui_trial/sequence')
                candidate=value['body']
                if not isinstance(candidate,dict):raise ValueError('direct_ui_trial/body')
                stamp,random=candidate.get('timestamp'),candidate.get('random')
                if type(stamp) is not int or not 0<=time.time()-stamp<=30 or type(random) is not int or not 0<=random<=999:
                    raise ValueError('direct_ui_trial/clock')
                expected=body(payload['credentials'],plan['target' if seq==1 else 'baseline'],plan['version'],
                    trial['guest'],stamp,random,trial['time_zone'])
                if not equivalent(expected,candidate):raise ValueError('direct_ui_trial/body')
                current();before(seq,plan)
                if armed:
                    receipt=store.advance(receipt,'prepared' if seq==1 else 'advance_verified',
                        'advance_pending' if seq==1 else 'restore_pending')
                claimed=seq
            elif event=='ack':
                if not armed or set(value)!={'kind','seq'} or seq!=claimed or seq!=acknowledged+1:
                    raise ValueError('direct_ui_trial/sequence')
                receipt=store.advance(receipt,'advance_pending' if seq==1 else 'restore_pending',
                    'advance_acknowledged' if seq==1 else 'restore_acknowledged');acknowledged=seq
            elif event=='verified':
                if not armed or set(value)!={'kind','seq'} or seq!=acknowledged or seq!=verified+1:
                    raise ValueError('direct_ui_trial/sequence')
                current();after(seq,plan)
                receipt=store.advance(receipt,'advance_acknowledged' if seq==1 else 'restore_acknowledged',
                    'advance_verified' if seq==1 else 'retired');verified=seq
            else:raise ValueError('direct_ui_trial/event')
            reply(child.stdin,dict(kind=event,seq=seq,ok=True));waiting=None
        if (child.wait(timeout=15) or not isinstance(runner,dict) or runner.get('result')!='PASS'
                or runner.get('profile_removed') is not True or runner.get('credential_file_audit') is not True
                or runner.get('installed_bytes_match') is not True or runner.get('steps')!=(2 if armed else 0)
                or runner.get('posts')!=(2 if armed else 0) or runner.get('blocked') is not (not armed)
                or planned!=1 or claimed!=(2 if armed else 1) or acknowledged!=(2 if armed else 0)
                or verified!=(2 if armed else 0)):
            raise ValueError('direct_ui_trial/incomplete')
        report.update(result='NATIVE_DIRECT_UI_ROUNDTRIP_VERIFIED' if armed else 'NATIVE_DIRECT_UI_DISARMED_VERIFIED',
            original_position_restored=armed,source_and_body_independently_verified=True,no_automatic_replay=True,
            temporary_profile_removed=True,credential_file_audit=True,installed_bytes_match=True)
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',no_automatic_replay=True)
        if isinstance(error,ValueError) and re.fullmatch('direct_ui_trial/[a-z_]+',str(error)):
            report['reason']=str(error)
        if child is not None and child.poll() is None and waiting is not None:
            try:reply(child.stdin,dict(kind=waiting.get('kind'),seq=waiting.get('seq'),ok=False))
            except Exception:pass
        raise
    finally:
        report.update(body_checks=claimed,explicit_success_receipts=acknowledged,independent_steps=verified,
            account_data_posts=claimed if armed and not payload.get('mock_endpoint') else 0,
            synthetic_posts=claimed if armed and payload.get('mock_endpoint') else 0)
        if child is not None:stop(child)
