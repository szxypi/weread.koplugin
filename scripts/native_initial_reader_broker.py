"""Independent one-slot native Reader plan/claim/ACK gate. Never sends HTTP."""
from copy import deepcopy
import re,subprocess,time
from native_trial_pipe import Frames,write_initial,reply,stop
from native_initial_reader_contract import validate_payload,validate_result
from native_initial_reader_model import validate_plan
from native_initial_position import valid_no_chapter
from secure_native_txt_roundtrip import point
from native_txt_read_model import body
from verify_native_position_lua import equivalent


def check_metadata(metadata,plan,reader_percent,bind):
    fields={'book_id','before','desired','counts','version','shelf_sha256','source_sha256','file_id','basis'}
    if not isinstance(metadata,dict) or set(metadata)!=fields:raise ValueError('initial_reader/metadata')
    valid_no_chapter(metadata['before']);point(metadata['desired'])
    if (metadata['basis']!='raw_txt_utf16' or metadata['book_id']!=plan['target']['book_id']
            or metadata['before']!=plan['baseline']['native'] or not equivalent(metadata['counts'],plan['counts'])
            or type(metadata['version']) is not int or metadata['version']!=plan['version']
            or metadata['source_sha256']!=plan['source_sha256'] or metadata['shelf_sha256']!=plan['native_shelf_sha256']
            or not isinstance(metadata['file_id'],str) or not re.fullmatch('[a-f0-9]{64}',metadata['file_id'])
            or type(reader_percent) is not int or not 0<=reader_percent<=100 or metadata['desired']['raw_percent']!=reader_percent
            or any(metadata['desired'][k]!=plan['target'][k] for k in plan['target'] if k!='raw_percent')
            or bind and (metadata['desired']['raw_percent']!=plan['target']['raw_percent'] or metadata['file_id']!=plan['source_file_id'])):
        raise ValueError('initial_reader/metadata')
    selected=deepcopy(plan);selected['target']['raw_percent']=reader_percent;selected['source_file_id']=metadata['file_id']
    return validate_plan(selected)


def execute(payload,command,store,report,*,prepare=False,current=None,before=None,after=None):
    trial=payload['native_initial_reader'];armed=trial['armed'];plan=deepcopy(trial['plan'])
    validate_payload(payload,armed,payload.get('reader_mock_port'));state,receipt=store.read()
    if (type(prepare) is not bool or armed and prepare or trial['bind_percent'] is prepare
            or prepare and state is not None or not prepare and (not state or state['phase']!='prepared' or state['plan']!=plan)):
        raise ValueError('initial_reader/intent')
    child=awaiting=runner=None;planned=body_steps=ack_steps=verified_steps=0
    try:
        if current:current()
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,trial['rpc_token'],timeout=420)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':
                runner=validate_result(value,armed,payload['vid']);report['native_ui']={k:v for k,v in runner.items() if k!='cookies'};break
            awaiting=value;event=value.get('kind')
            if type(value.get('seq')) is not int or value['seq']!=1:raise ValueError('initial_reader/sequence')
            if event=='plan':
                if planned or set(value)!={'kind','seq','metadata','reader_percent'}:raise ValueError('initial_reader/plan_sequence')
                selected=check_metadata(value['metadata'],plan,value['reader_percent'],trial['bind_percent'])
                if not prepare and selected!=state['plan']:raise ValueError('initial_reader/plan_changed')
                plan=selected;planned=1
            elif event in ('claim','dry_body'):
                if not planned or body_steps or set(value)!={'kind','seq','body'} or event!=('claim' if armed else 'dry_body'):
                    raise ValueError('initial_reader/body_sequence')
                candidate=value['body'];stamp=candidate.get('timestamp') if isinstance(candidate,dict) else None
                random=candidate.get('random') if isinstance(candidate,dict) else None
                if type(stamp) is not int or not 0<=time.time()-stamp<=30 or type(random) is not int or not 0<=random<=999:raise ValueError('initial_reader/clock')
                expected=body(payload['native_grant'],plan['target'],plan['version'],trial['guest'],stamp,random,trial['time_zone'])
                if not equivalent(expected,candidate):raise ValueError('initial_reader/body')
                if current:current()
                if before:before(plan)
                if armed:receipt=store.advance(receipt,'prepared','pending')
                body_steps=1
            elif event=='ack':
                if not armed or body_steps!=1 or ack_steps or set(value)!={'kind','seq'}:raise ValueError('initial_reader/ack_sequence')
                receipt=store.advance(receipt,'pending','acknowledged');ack_steps=1
            elif event=='verified':
                if not armed or ack_steps!=1 or verified_steps or set(value)!={'kind','seq'}:raise ValueError('initial_reader/verified_sequence')
                if current:current()
                if after:after(plan)
                receipt=store.advance(receipt,'acknowledged','retired');verified_steps=1
            else:raise ValueError('initial_reader/event')
            reply(child.stdin,dict(kind=event,seq=1,ok=True));awaiting=None
        if child.wait(timeout=15) or runner['result']!='PASS' or body_steps!=1 or verified_steps!=(1 if armed else 0):raise ValueError('initial_reader/native_failed')
        if prepare:
            if current:current()
            if before:before(plan)
            store.reserve(plan)
        report.update(result='NATIVE_INITIAL_READER_PREPARED' if prepare else 'NATIVE_INITIAL_READER_VERIFIED' if armed else 'NATIVE_INITIAL_READER_DISARMED_VERIFIED',
                      original_no_chapter_restored=False,first_position_established=armed,no_automatic_replay=True)
        return runner['cookies']
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and re.fullmatch('initial_reader/[a-z_]+',str(error)):report['reason']=str(error)
        if child is not None and child.poll() is None and awaiting is not None:
            try:reply(child.stdin,dict(kind=awaiting.get('kind'),seq=1,ok=False))
            except Exception:pass
        raise
    finally:
        report.update(planned=planned,body_checks=body_steps,explicit_success_receipts=ack_steps,independent_steps=verified_steps,
                      claimed_posts=body_steps if armed else 0,account_data_posts=body_steps if armed and 'reader_mock_port' not in payload else 0,
                      synthetic_posts=body_steps if armed and 'reader_mock_port' in payload else 0)
        if child is not None:stop(child)
