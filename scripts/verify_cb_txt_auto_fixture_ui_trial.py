#!/usr/bin/env python3
"""Verify TXT timer and close sync using one fresh self-authored fixture.

Each UI run is preceded by a blocked-write rehearsal and followed by two
independent dual-channel reads. The permanent scopes cannot be reused.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import tempfile

from cb_fixture_close_intent import Intent as CloseIntent
from cb_fixture_timer_intent import Intent as TimerIntent
from cb_initial_fixture_intent import Intent as InitialIntent
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from txt_coordinates import PlainSource
from verify_cb_initial_fixture_ui_trial import ui_command
from verify_cb_txt_fixture import Journal, Receipt
from verify_cb_txt_initial_fixture_ui_trial import execute as first_execute
from verify_cb_txt_manual_fixture_ui_trial import manual_command, run_manual, validate_pair


def stores():
    def backend(suffix):return MacKeychain(service='org.codex.weread.cb-txt-auto-ui-'+suffix+'-v1',account=ACCOUNT)
    def lock(suffix):
        path=Path(tempfile.gettempdir())/('codex-cb-txt-auto-ui-'+suffix+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend('upload'),lock=lock('upload')),Receipt(backend=backend('receipt')),
            InitialIntent(backend=backend('initial'),lock=lock('initial')),
            TimerIntent(backend=backend('timer'),lock=lock('timer')),
            CloseIntent(backend=backend('close'),lock=lock('close')))


def run_auto(command,payload,width,height,dpi):
    if payload.get('armed') is not True or (payload.get('timer') is True)==(payload.get('close') is True):
        raise ValueError('cb_txt_auto_ui/scope')
    child=subprocess.run([*command,'--width',str(width),'--height',str(height),'--dpi',str(dpi)],
        input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=780)
    if len(child.stdout)>65536:raise ValueError('cb_txt_auto_ui/result')
    value=json.loads(child.stdout)
    expected=dict(result='PASS',profile_removed=True,installed_bytes_match=True,native_choice=True,actual_source=True,
        upload_confirmed=True,fresh_process=True,pending_cleared=True,journal_cleared=True,automatic_disabled=False,
        writes=3,denied=0,credentials_not_persisted=True)
    expected['timer_verified' if payload.get('timer') else 'close_verified']=True
    if child.returncode or value!=expected:raise ValueError('cb_txt_auto_ui/result')
    return True


def auto_trial(context,report,timer_intent,close_intent,command,*,dry_runner=run_manual,auto_runner=run_auto,attest=manual_command):
    plan,sample=context['plan'],context['sample'];model=PlainSource(sample['source'])
    first,following=plan['first'],plan['following']
    if following-first!=1:return False
    summaries={offset:model.excerpt(offset)['text'] for offset in (first,following)}
    if not all(summaries.values()):return False
    fingerprint=hashlib.sha256((context['source_hash']+':'+str(first)+':'+str(following)).encode()).hexdigest()
    previous=context['initial_observed'];report['auto_stages']=[]
    for mode,intent in (('timer',timer_intent),('close',close_intent)):
        reservation=intent.reserve(context['owner'],context['target'],context['attempt'],fingerprint)
        for index,(width,height,dpi) in enumerate(((600,800,167),(1264,1680,300))):
            if (not context['authority']() or not context['shelf_current']()
                    or context['attest']()!=context['command'] or attest()!=command):return False
            before=validate_pair(context,first,summaries[first])
            if before!=previous or validate_pair(context,first,summaries[first])!=before:return False
            payload=dict(book=context['target'],chapter=plan['chapter'],chapter_idx=plan['index'],first_offset=first,
                next_offset=following,expected_summary=summaries[following],source=sample['source'],source_format='web_txt',
                chapters=context['chapters'],book_version=0,owner=context['owner'],cookies=context['cookies'](),armed=False)
            if not dry_runner(command,payload,width,height,dpi):return False
            if (not context['authority']() or not context['shelf_current']()
                    or validate_pair(context,first,summaries[first])!=before
                    or context['attest']()!=context['command'] or attest()!=command):return False
            prefix='first' if index==0 else 'second';permit=None
            for suffix in ('enter','manual',mode):
                permit=intent.claim(reservation,prefix+'_'+suffix)
                if not intent.verify(reservation,permit):return False
            if not context['authority']() or not intent.verify(reservation,permit):return False
            payload.update(cookies=context['cookies'](),armed=True,timer_summary=summaries[first])
            payload[mode]=True;report['position_writes_uncertain']=True
            if not auto_runner(command,payload,width,height,dpi):return False
            report['position_writes_known']+=3;report['position_writes_uncertain']=False
            current=validate_pair(context,first,summaries[first])
            if validate_pair(context,first,summaries[first])!=current or not context['shelf_current']() or not context['authority']():return False
            previous=current
            report['auto_stages'].append(dict(mode=mode,screen='600x800' if index==0 else '1264x1680',
                dry_run_blocked=True,writes=3,dual_readback=True,offline_reopen=True))
    return len(report['auto_stages'])==4


def execute(saved,session,native,grant,journal,receipt,initial,timer,close,first_command,second_command,*,apply=False,
            first=first_execute,dry_runner=run_manual,auto_runner=run_auto,attest=manual_command):
    if timer.backend.load() is not None or close.backend.load() is not None:
        return dict(result='UNVERIFIED',phase='preflight',account_data_writes_known=0,position_writes_uncertain=False)
    def after(context,report):
        return auto_trial(context,report,timer,close,second_command,dry_runner=dry_runner,auto_runner=auto_runner,attest=attest)
    result=first(saved,session,native,grant,journal,receipt,initial,first_command,apply=apply,after_verified=after)
    if result.get('result')=='CB_TXT_FIRST_NATIVE_UI_VERIFIED' and len(result.get('auto_stages',[]))==4:
        result['result']='CB_TXT_AUTO_NATIVE_UI_VERIFIED'
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes_known=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        first_command,second_command=ui_command(),manual_command();session=SessionStore();saved=session.load()
        native=NativeSessionStore();grant=native.load(saved['vid'])
        result=execute(saved,session,native,grant,*stores(),first_command,second_command,apply=args.apply)
    except Exception:
        result=dict(result='UNVERIFIED',phase='unknown' if args.apply else 'preflight',
                    account_data_writes_known=None if args.apply else 0,position_writes_uncertain=args.apply)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(result))
    return int(result['result'] not in ('READ_ONLY_PREVIEW','CB_TXT_AUTO_NATIVE_UI_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
