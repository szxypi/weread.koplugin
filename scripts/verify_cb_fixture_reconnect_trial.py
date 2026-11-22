#!/usr/bin/env python3
"""One fresh multipage fixture: bounded offline reconnect and native sync.

Offline by default. Separate durable records scope the upload, first position,
and four UI writes. A source-bound discovery and denied-write rehearsal precede
each screen; unknown results retain the fixture and cannot be replayed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import tempfile

from cb_cloud_position import observed,state
from cb_existing_position_intent import Intent as ManualIntent,digest as intent_digest
from cb_initial_fixture_intent import Intent as InitialIntent
from reading_epub_trial import Journal,check as check_plan,prepare as prepare_plan
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_upload_epub import build_reading
from verify_cb_initial_fixture_ui_trial import run as initial_run,target_matches,ui_command
from verify_cb_txt_manual_fixture_ui_trial import manual_command
from verify_source_coordinates import CoordinateError,FilteredSource
from verify_synthetic_epub_upload import run as upload_run


def stores():
    def backend(name):return MacKeychain(service='org.codex.weread.cb-reconnect-fixture-'+name+'-v1',account=ACCOUNT)
    def lock(name):
        path=Path(tempfile.gettempdir())/('codex-cb-reconnect-fixture-'+name+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend('upload'),lock=lock('upload')),
            InitialIntent(backend=backend('initial'),lock=lock('initial')),
            ManualIntent(backend=backend('manual'),lock=lock('manual')))


def run_ui(command,payload,width,height,dpi):
    if (not isinstance(payload,dict) or payload.get('reconnect') is not True or type(payload.get('armed')) is not bool
            or 'reconnect_discover' in payload and payload['reconnect_discover'] is not True
            or payload.get('reconnect_discover') is True and payload['armed']
            or 'reconnect_page' in payload and (type(payload['reconnect_page']) is not int or not 2<=payload['reconnect_page']<=32)):
        raise ValueError('cb_reconnect/scope')
    child=subprocess.run([*command,'--width',str(width),'--height',str(height),'--dpi',str(dpi)],
        input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=780)
    if len(child.stdout)>65536:raise ValueError('cb_reconnect/result')
    value=json.loads(child.stdout)
    if payload.get('reconnect_discover') is True:
        offset=value.get('offset')
        if type(offset) is not int or not 0<=offset<=16*1024*1024:raise ValueError('cb_reconnect/offset')
        expected=dict(result='DISCOVERED',offset=offset,profile_removed=True,installed_bytes_match=True,
                      offline_intent=True,writes=0,denied=0,credentials_not_persisted=True)
    elif not payload['armed']:
        expected=dict(result='DRY_RUN',profile_removed=True,installed_bytes_match=True,native_choice=True,
                      write_blocked=True,writes=0,denied=1,credentials_not_persisted=True,
                      offline_intent=True,reconnect_choice=True)
    else:
        expected=dict(result='PASS',profile_removed=True,installed_bytes_match=True,native_choice=True,actual_source=True,
                      upload_confirmed=True,fresh_process=True,pending_cleared=True,journal_cleared=True,
                      automatic_disabled=True,writes=2,denied=0,credentials_not_persisted=True,
                      offline_intent=True,reconnect_choice=True)
    if child.returncode or value!=expected:raise ValueError('cb_reconnect/result')
    return value


def verify_pair(context,offset,summary):
    native,web=context['pair']();target=dict(context['plan'],first=offset);chapters=context['sample']['chapters']
    if not target_matches(native,target,chapters,'native',summary) or not target_matches(web,target,chapters,'web',summary):
        raise ValueError('cb_reconnect/position')
    if state(native,context['target'],chapters,'native')['raw_percent']!=state(web,context['target'],chapters,'web')['raw_percent']:
        raise ValueError('cb_reconnect/percent')
    values={channel:observed(raw,context['target'],chapters,channel) for channel,raw in (('native',native),('web',web))}
    counts=values['native']['counters']
    if any(not counts[key]['present'] or type(counts[key]['value']) is not int or counts[key]['value']!=0
           for key in ('readingTime','recordReadingTime','ttsTime')):raise ValueError('cb_reconnect/counts')
    return values


def source_summary(model,offset):
    """Independently bind an exact visible boundary using surrounding text."""
    visible=[i for i,char in enumerate(model.characters) if not char.isspace()]
    characters=[model.characters[i] for i in visible];starts=[model.starts[i] for i in visible]
    found=[i for i,value in enumerate(starts) if value==offset]
    if type(offset) is not int or len(found)!=1:raise ValueError('cb_reconnect/source_point')
    index=found[0]
    for width in (24,48,96,192):
        first,last=max(0,index-width),min(len(characters),index+width)
        quote=''.join(characters[first:last])
        try:
            if model.locate(quote)[0]==starts[first]:break
        except CoordinateError:pass
    else:raise ValueError('cb_reconnect/source_ambiguous')
    result=''.join(characters[index:index+20])
    if not result:raise ValueError('cb_reconnect/source_point')
    return result


def reconnect_trial(context,report,intent,command,*,runner=run_ui,attest=manual_command,resume=False):
    plan,sample=context['plan'],context['sample'];model=FilteredSource(sample['source'],allow_multiple_bodies=True)
    def summary(offset):return source_summary(model,offset)
    before=plan['first'];before_summary=summary(before)
    if not before_summary:return False
    fingerprint=hashlib.sha256((context['source_hash']+':'+str(before)).encode()).hexdigest()
    if resume:
        raw=intent.backend.load()
        try:reservation=json.loads(raw)
        except (TypeError,ValueError,UnicodeError):raise ValueError('cb_reconnect/resume') from None
        expected=dict(schema=1,scope=ACCOUNT,owner=intent_digest(context['owner']),book=intent_digest(context['target']),
                      attempt=context['attempt'],baseline=fingerprint,claimed=0)
        if (not isinstance(reservation,dict) or type(reservation.get('schema')) is not int
                or type(reservation.get('claimed')) is not int or reservation!=expected or not intent.verify(reservation,raw)):
            raise ValueError('cb_reconnect/resume')
    else:reservation=intent.reserve(context['owner'],context['target'],context['attempt'],fingerprint)
    previous=context['initial_observed'];report['reconnect_stages']=[]
    for index,(width,height,dpi,stages) in enumerate(((600,800,167,('write_enter','write_same')),
                                                     (1264,1680,300,('write_probe','write_restore')))):
        if (not context['authority']() or not context['shelf_current']()
                or context['attest']()!=context['command'] or attest()!=command):return False
        baseline=verify_pair(context,before,before_summary)
        if baseline!=previous or verify_pair(context,before,before_summary)!=baseline:return False
        payload=dict(book=context['target'],chapter=plan['chapter'],chapter_idx=plan['index'],first_offset=before,next_offset=before,
                     source=sample['source'],source_format='web_xhtml',chapters=context['chapters'],book_version=0,
                     owner=context['owner'],cookies=context['cookies'](),armed=False,reconnect=True,reconnect_discover=True)
        discovered=runner(command,payload,width,height,dpi);after=discovered['offset']
        if type(after) is not int or after==before:return False
        after_summary=summary(after)
        if not after_summary:return False
        if (not context['authority']() or not context['shelf_current']()
                or verify_pair(context,before,before_summary)!=baseline or attest()!=command):return False
        payload.pop('reconnect_discover');payload.update(next_offset=after,expected_summary=after_summary,cookies=context['cookies']())
        if runner(command,payload,width,height,dpi)['result']!='DRY_RUN':return False
        if (not context['authority']() or not context['shelf_current']() or verify_pair(context,before,before_summary)!=baseline
                or context['attest']()!=context['command'] or attest()!=command):return False
        permit=None
        for stage in stages:
            permit=intent.claim(reservation,stage)
            if not intent.verify(reservation,permit):return False
        if not context['authority']() or not intent.verify(reservation,permit):return False
        payload.update(cookies=context['cookies'](),armed=True);report['position_writes_uncertain']=True
        if runner(command,payload,width,height,dpi)['result']!='PASS':return False
        report['position_writes_known']+=2;report['position_writes_uncertain']=False
        current=verify_pair(context,after,after_summary)
        if verify_pair(context,after,after_summary)!=current or not context['shelf_current']() or not context['authority']():return False
        previous=current;before=after;before_summary=after_summary
        report['reconnect_stages'].append(dict(screen='600x800' if index==0 else '1264x1680',offline_intent=True,
            reconnect_choice=True,dry_run_blocked=True,writes=2,dual_readback=True,fresh_offline_reopen=True))
    return len(report['reconnect_stages'])==2 and intent.verify(reservation,permit)


def execute(saved,session,native,grant,journal,initial,manual,first_command,second_command,*,apply=False,
            first=initial_run,upload=upload_run,runner=run_ui,attest=manual_command):
    if manual.backend.load() is not None:
        return dict(result='UNVERIFIED',phase='preflight',account_data_writes_known=0,position_writes_uncertain=False)
    def uploader(probe,journal_arg,grant_arg,grant_check,source,*,apply,cleanup_gate):
        if journal_arg is not journal or grant_arg!=grant:raise ValueError('cb_reconnect/authority')
        return upload(probe,journal,grant,grant_check,source,apply=apply,cleanup_gate=cleanup_gate,
                      fixture_builder=build_reading,prepare_plan=prepare_plan,check_plan=check_plan)
    def after(context,report):return reconnect_trial(context,report,manual,second_command,runner=runner,attest=attest)
    result=first(saved,session,native,grant,journal,initial,first_command,apply=apply,uploader=uploader,after_verified=after)
    if result.get('result')=='CB_FIRST_NATIVE_UI_VERIFIED' and len(result.get('reconnect_stages',[]))==2:
        result['result']='CB_FIXTURE_OFFLINE_RECONNECT_VERIFIED'
    elif apply and result.get('result')=='UNVERIFIED':
        # The outer orchestration may have stopped after a write but before it
        # returned counters. Never imply that an interrupted attempt wrote zero.
        result['account_data_writes_known']=None;result['position_writes_uncertain']=True
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes_known=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        first_command,second_command=ui_command(),manual_command()
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        result=execute(saved,session,native,grant,*stores(),first_command,second_command,apply=args.apply)
    except Exception:
        result=dict(result='UNVERIFIED',phase='unknown' if args.apply else 'preflight',
                    account_data_writes_known=None if args.apply else 0,position_writes_uncertain=args.apply)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(result));return int(result['result'] not in ('READ_ONLY_PREVIEW','CB_FIXTURE_OFFLINE_RECONNECT_VERIFIED'))

if __name__=='__main__':raise SystemExit(main())
