"""Supervise one native first-position UI write; no HTTP sender lives here."""
from copy import deepcopy
import hashlib
import re
import subprocess
import time

from native_initial_position import valid_no_chapter
from native_time_capture_evidence import account_key
from native_trial_pipe import Frames,reply,stop,write_initial
from native_txt_read_model import body as position_body
from readtime_upload_model import confirmed
from verify_native_direct_position_owner import independent_offset
from verify_native_position_lua import equivalent
from verify_source_coordinates import FilteredSource


def bind_metadata(metadata,anchor,expected,raw):
    fields={'book_id','before','desired','counts','version','shelf_sha256','source_sha256','file_id','basis'}
    if not isinstance(metadata,dict) or set(metadata)!=fields or not isinstance(anchor,dict) or set(anchor)!={'text','point_offset'}:
        raise ValueError('initial_ui/metadata')
    valid_no_chapter(metadata['before'])
    if (not isinstance(raw,bytes) or hashlib.sha256(raw).hexdigest()!=expected['source_sha256']
            or metadata['basis']!='filtered_xhtml_utf16' or metadata['book_id']!=expected['book_id']
            or metadata['before']!=expected['native_before'] or metadata['counts']!=expected['counts']
            or metadata['version']!=expected['version'] or metadata['shelf_sha256']!=expected['native_shelf']
            or metadata['source_sha256']!=expected['source_sha256'] or not isinstance(metadata['file_id'],str)
            or not re.fullmatch('[a-f0-9]{64}',metadata['file_id'])):raise ValueError('initial_ui/metadata')
    target=metadata['desired']
    if (not isinstance(target,dict) or set(target)!={'book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary'}
            or target['book_id']!=expected['book_id'] or target['chapter_uid']!=expected['uid']
            or target['chapter_idx']!=expected['chapter_idx'] or target['raw_percent']!=0):raise ValueError('initial_ui/target')
    point=dict(ok=True,text=anchor['text'],point_offset=anchor['point_offset'],offset=target['chapter_offset'])
    if not independent_offset(raw,point):raise ValueError('initial_ui/source')
    model=FilteredSource(raw.decode('utf-8'),allow_multiple_bodies=True)
    visible=[i for i,char in enumerate(model.characters) if not char.isspace()]
    positions=[i for i,index in enumerate(visible) if model.starts[index]==target['chapter_offset']]
    if len(positions)!=1:raise ValueError('initial_ui/source')
    at=positions[0];summary=''.join(model.characters[i] for i in visible[at:at+20])
    if not summary or target['summary']!=summary:raise ValueError('initial_ui/summary')
    return deepcopy(metadata)


def execute(payload,command,intent,raw,report,*,current,before,after):
    armed=payload['armed'];expected=payload['expected'];token=payload['token']
    if type(armed) is not bool or not isinstance(command,list) or not command or intent.read()!=(None,None):
        raise ValueError('initial_ui/intent')
    def check_current():
        if current() is not True:raise ValueError('initial_ui/session')
    def check_snapshot(callback,selection):
        if callback(selection) is not True:raise ValueError('initial_ui/snapshot')
    child=waiting=metadata=receipt=None;events=[]
    try:
        check_current();child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=420,max_frame=65536)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':
                runner=value
                if payload.get('mock_endpoint') and isinstance(value,dict):
                    report['synthetic_diagnostic']={key:value[key] for key in ('stage','diagnostic') if key in value}
                break
            waiting=value;name=value.get('kind');allow=False
            if name=='plan' and events==[] and set(value)=={'kind','metadata','anchor'}:
                metadata=bind_metadata(value['metadata'],value['anchor'],expected,raw)
                check_current();check_snapshot(before,metadata);allow=True
            elif name=='claim' and events==['plan'] and set(value)=={'kind','body','selection','record'}:
                record=value['record'];request=value['body']
                if (not isinstance(record,dict) or record.get('phase')!='pending' or record.get('account')!=account_key(payload['credentials']['vid'])
                        or not equivalent(record.get('metadata'),metadata) or not equivalent(value['selection'],metadata)
                        or not isinstance(request,dict)):raise ValueError('initial_ui/record')
                stamp,random=request.get('timestamp'),request.get('random')
                if type(stamp) is not int or not 0<=time.time()-stamp<=30 or type(random) is not int or not 0<=random<=999:
                    raise ValueError('initial_ui/clock')
                calculated=position_body(payload['credentials'],metadata['desired'],metadata['version'],payload['guest'],stamp,random,payload['time_zone'])
                if not equivalent(request,calculated):raise ValueError('initial_ui/body')
                check_current();check_snapshot(before,metadata)
                check_current()
                if not 0<=time.time()-stamp<=30:raise ValueError('initial_ui/clock')
                if armed:
                    plan=dict(selection=deepcopy(metadata),record=deepcopy(record),body=deepcopy(request),baseline=deepcopy(expected))
                    receipt=intent.claim(plan);report.update(account_data_posts=None,dispatch_may_have_occurred=True);allow=True
            elif name=='ack' and events==['plan','claim'] and armed and set(value)=={'kind','status','response'}:
                if value['status']!=200 or not confirmed(value['response']):raise ValueError('initial_ui/receipt')
                check_current()
                receipt=intent.advance(receipt,'acknowledged');report['account_data_posts']=1;allow=True
            elif name=='verified' and events==['plan','claim','ack'] and armed and set(value)=={'kind'}:
                check_current();check_snapshot(after,metadata);check_current();receipt=intent.advance(receipt,'verified');allow=True
            else:raise ValueError('initial_ui/order')
            events.append(name);reply(child.stdin,dict(kind=name,ok=allow));waiting=None
            if name!='claim' and not allow:raise ValueError('initial_ui/denied')
        if (child.wait(timeout=15)!=0 or not isinstance(runner,dict) or runner.get('profile_removed') is not True
                or runner.get('result')!=('INITIAL_UI_VERIFIED' if armed else 'DRY_BLOCKED')
                or events!=(['plan','claim','ack','verified'] if armed else ['plan','claim'])):
            raise ValueError('initial_ui/runner')
        if not armed and intent.read()!=(None,None):raise ValueError('initial_ui/dry')
        report.update(result='INITIAL_NATIVE_UI_VERIFIED' if armed else 'INITIAL_NATIVE_UI_DRY_VERIFIED',
            profile_removed=True,source_and_body_independently_verified=True,no_automatic_replay=True)
    except (Exception,KeyboardInterrupt):
        if child is not None and child.poll() is None and waiting is not None:
            try:reply(child.stdin,dict(kind=waiting.get('kind'),ok=False))
            except Exception:pass
        raise
    finally:
        if child is not None:stop(child)
