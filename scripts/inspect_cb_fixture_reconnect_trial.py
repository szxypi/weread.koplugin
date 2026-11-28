#!/usr/bin/env python3
"""Read-only diagnosis of one interrupted, unclaimed reconnect fixture."""
import argparse
import hashlib
import json
import resource
import subprocess
from urllib.parse import urlencode

from cb_existing_position_intent import digest
from cb_fixture_position import plan as position_plan
from reading_epub_trial import check as check_plan
from secure_native_session import NativeSessionStore
from secure_weread_session import ACCOUNT,SessionStore
from synthetic_upload_epub import TEXT
from verify_cb_fixture_highlight_trial import ScopedNative
from verify_cb_fixture_reconnect_trial import source_summary,stores,verify_pair
from verify_cb_initial_fixture_trial import NativeRead,SourceRead
from verify_cb_txt_manual_fixture_ui_trial import manual_command
from verify_eink_login import BASE as NATIVE
from verify_personal_upload_trial import Probe as UploadProbe
from verify_source_coordinates import FilteredSource
from verify_web_source_progress import BASE as WEB,WebSourceProbe


def inspect(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,fixture_only=True)
    if not args.saved_session:print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=web=None;phase='session'
    try:
        session=SessionStore();saved=session.load();owner=saved['vid'];native_store=NativeSessionStore();grant=native_store.load(owner)
        journal,initial,manual=stores();upload,receipt=journal.read()
        if not upload or upload['phase']!='imported' or upload['plan']['owner']!=owner:raise ValueError('scope')
        target=upload['target'];initial_raw=initial.backend.load();manual_raw=manual.backend.load()
        initial_value=json.loads(initial_raw);manual_value=json.loads(manual_raw)
        for value,raw,store,claimed in ((initial_value,initial_raw,initial,1),(manual_value,manual_raw,manual,0)):
            if (not isinstance(value,dict) or set(value)!={'schema','scope','owner','book','attempt','baseline','claimed'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or value['owner']!=digest(owner) or value['book']!=digest(target) or value['attempt']!=upload['attempt']
                    or type(value['claimed']) is not int or value['claimed']!=claimed or not store.verify(value,raw)):
                raise ValueError('intent')
        def current():return native_store.load(owner)==grant and journal.read()==(upload,receipt) and initial.backend.load()==initial_raw and manual.backend.load()==manual_raw
        phase='shelf';probe=UploadProbe(journal,lambda value:current() and value==grant)
        shelf=probe.shelf(grant);check_plan(upload['plan'],grant,shelf,target,True)
        if any(str(item)==target for group in shelf.get('archive',[]) for item in group.get('bookIds',[])):raise ValueError('grouped')
        phase='source';web=SourceRead();web.vid=owner;web.book_id=target;web.allowed={target}
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.inspect(target);web.verify_account()
        if sample['source_format']!='web_xhtml' or TEXT not in sample['source']:raise ValueError('source')
        plan=position_plan(target,sample,require_unstarted=False)
        fingerprint=hashlib.sha256((sample['source_raw_sha256']+':'+str(plan['first'])).encode()).hexdigest()
        if initial_value['baseline']!=fingerprint or manual_value['baseline']!=fingerprint:raise ValueError('source_binding')
        chapters=[]
        for row in sample['chapters']:
            item=dict(row)
            if type(item.get('wordCount')) not in (int,float) or item['wordCount']<=0:item['wordCount']=1000
            chapters.append(item)
        reader=NativeRead(grant,target)
        def pair():
            if not current():raise ValueError('stale')
            n=reader.request('first_progress',NATIVE+'/book/getProgress?'+urlencode(dict(bookId=target)),credentials=grant)
            w=WebSourceProbe();w.vid=owner;w.book_id=target
            try:
                for key,value in saved['cookies'].items():w.set_cookie(key,value)
                w.verify_account();raw=w.request('progress_after',WEB+'/web/book/getProgress?bookId='+target);w.verify_account()
                return n,raw
            finally:w.close()
        context=dict(pair=pair,plan=plan,sample=sample,target=target)
        model=FilteredSource(sample['source'],allow_multiple_bodies=True)
        def summary(offset):return source_summary(model,offset)
        phase='position';baseline=verify_pair(context,plan['first'],summary(plan['first']))
        if verify_pair(context,plan['first'],summary(plan['first']))!=baseline:raise ValueError('unstable')
        phase='notes';notes=ScopedNative(target,grant,lambda:current(),None).observe(grant)
        if notes['marks']['updated']!={} or notes['marks']['chapters']!={} or notes['thoughts']!={}:raise ValueError('notes')
        command=manual_command();payload=dict(book=target,chapter=plan['chapter'],chapter_idx=plan['index'],first_offset=plan['first'],next_offset=plan['first'],
            source=sample['source'],source_format='web_xhtml',chapters=chapters,book_version=0,owner=owner,cookies=saved['cookies'],
            armed=False,reconnect=True,reconnect_discover=True)
        def ui(value):
            proc=subprocess.run([*command,'--width','600','--height','800','--dpi','167'],input=json.dumps(value,ensure_ascii=False).encode(),
                stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=780)
            if len(proc.stdout)>65536:raise ValueError('ui')
            result=json.loads(proc.stdout)
            out={'result':result.get('result') if result.get('result') in ('DISCOVERED','DRY_RUN','UNVERIFIED') else 'UNKNOWN',
                 'profile_removed':result.get('profile_removed') is True,'installed_bytes_match':result.get('installed_bytes_match') is True}
            if result.get('failure_phase') in ('decode','prepare','source_ready','offline_move','choice','upload','reopen'):out['failure_phase']=result['failure_phase']
            if type(result.get('failure_line')) is int:out['failure_line']=result['failure_line']
            return proc.returncode,result,out
        phase='discovery';report['pages_checked']=0;offset=expected=None
        for page in range(2,13):
            payload['reconnect_page']=page
            status,raw,report['discovery']=ui(payload);report['pages_checked']+=1
            if status or raw.get('result')!='DISCOVERED' or type(raw.get('offset')) is not int:raise ValueError('discovery')
            candidate=raw['offset']
            try:captured=summary(candidate)
            except ValueError as error:
                message=str(error)
                report['anchor_error']=message if message in ('cb_reconnect/source_point','cb_reconnect/source_ambiguous') else 'other'
                continue
            if candidate!=plan['first'] and captured:
                offset,expected=candidate,captured;report['selected_page']=page;break
        phase='target_summary'
        if offset is None or not expected:raise ValueError('target')
        phase='after_discovery';
        if verify_pair(context,plan['first'],summary(plan['first']))!=baseline or not current():raise ValueError('stale')
        payload.pop('reconnect_discover');payload.update(next_offset=offset,expected_summary=expected)
        phase='dry';status,raw,report['dry']=ui(payload)
        if status or raw.get('result')!='DRY_RUN' or raw.get('writes')!=0:raise ValueError('dry')
        phase='final_readback'
        if verify_pair(context,plan['first'],summary(plan['first']))!=baseline or not current():raise ValueError('stale')
        check_plan(upload['plan'],grant,probe.shelf(grant),target,True)
        report.update(result='READ_ONLY_DIAGNOSIS_VERIFIED',fixture_bound=True,initial_position_confirmed=True,
                      manual_slots_claimed=0,notes_empty=True,dual_cloud_unchanged=True,fixture_retained=True)
    except Exception:
        report.update(result='UNVERIFIED',phase=phase)
    finally:
        if web:web.samples.clear();web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result']!='READ_ONLY_DIAGNOSIS_VERIFIED')

if __name__=='__main__':raise SystemExit(inspect())
