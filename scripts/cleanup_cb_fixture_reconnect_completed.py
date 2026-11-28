#!/usr/bin/env python3
"""Inspect and remove only the completed, owned reconnect fixture once."""
import argparse
import hashlib
import json
import resource
from urllib.parse import urlencode

from cb_cloud_position import state
from cb_fixture_position import plan as position_plan
from cloud_group_contract import project
from cloud_group_nonempty_workflow import strip_fixture
from finish_change_contract import flags
from reading_epub_trial import check as check_plan
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from synthetic_upload_epub import TEXT
from verify_cb_fixture_highlight_trial import ScopedNative
from verify_cb_fixture_reconnect_trial import source_summary,stores,verify_pair
from verify_cb_initial_fixture_trial import NativeRead,SourceRead
from verify_eink_login import BASE as NATIVE
from verify_personal_upload_trial import Probe as UploadProbe
from verify_source_coordinates import FilteredSource
from verify_web_source_progress import BASE as WEB,WebSourceProbe
from resume_cb_fixture_reconnect_trial import cleanup_once,verify_intent


def validate_fixture_shelf(source,target):
    row=flags(source).get(target)
    if (row is None or row['pinned'] not in ({'value':False},{'reason':'missing'})
            or row['finished'] not in ({'value':False},{'reason':'missing'})
            or row['private'] not in ({'value':True},{'reason':'missing'})):
        raise ValueError('cleanup/target_flags')
    for group in source.get('archive',[]):
        if not isinstance(group,dict):raise ValueError('cleanup/group')
        for key in ('bookIds','albumIds'):
            values=group.get(key,[])
            if not isinstance(values,list) or any(str(item)==target for item in values):raise ValueError('cleanup/group')
    return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    report=dict(result='OFFLINE_ONLY',position_posts=0,cleanup_posts=0,authentication_posts=0,fixture_only=True,private_data_in_report=False)
    if not args.saved_session:print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=source=None;phase='session';journal=probe=None
    try:
        session=SessionStore();saved=session.load();owner=saved['vid'];native_store=NativeSessionStore();grant=native_store.load(owner)
        journal,initial,manual=stores();upload,receipt=journal.read()
        if not upload or upload['phase']!='imported' or upload['plan']['owner']!=owner:raise ValueError('cleanup/scope')
        target=upload['target'];initial_raw=initial.backend.load();manual_raw=manual.backend.load()
        def session_current():return SessionStore().load()['vid']==owner and native_store.load(owner)==grant
        def owned():return (session_current() and journal.read()==(upload,receipt)
                            and initial.backend.load()==initial_raw and manual.backend.load()==manual_raw)
        probe=UploadProbe(journal,lambda value:session_current() and value==grant)
        phase='shelf';native_shelf=probe.shelf(grant);check_plan(upload['plan'],grant,native_shelf,target,True);validate_fixture_shelf(native_shelf,target)
        def web_shelf():
            web=WebSourceProbe();web.vid=owner
            try:
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account();raw=web.request('shelf',WEB+'/web/shelf/sync');web.verify_account();return raw
            finally:web.close()
        phase='web_shelf';web_initial=web_shelf();validate_fixture_shelf(web_initial,target);before=strip_fixture(web_initial,target)
        web_check=web_shelf();validate_fixture_shelf(web_check,target)
        if strip_fixture(web_check,target)!=before:raise ValueError('cleanup/shelf')
        phase='source';source=SourceRead();source.vid=owner;source.book_id=target;source.allowed={target}
        for key,value in saved['cookies'].items():source.set_cookie(key,value)
        source.verify_account();sample=source.inspect(target);source.verify_account()
        if (sample['source_format']!='web_xhtml' or TEXT not in sample['source']
                or set(source.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                or not all(source.last_checks.values())):raise ValueError('cleanup/source')
        plan=position_plan(target,sample,require_unstarted=False)
        fingerprint=hashlib.sha256((sample['source_raw_sha256']+':'+str(plan['first'])).encode()).hexdigest()
        verify_intent(initial,initial_raw,owner,target,upload['attempt'],fingerprint,1)
        verify_intent(manual,manual_raw,owner,target,upload['attempt'],fingerprint,4)
        reader=NativeRead(grant,target)
        def pair():
            if not owned():raise ValueError('cleanup/stale')
            n=reader.request('first_progress',NATIVE+'/book/getProgress?'+urlencode(dict(bookId=target)),credentials=grant)
            web=WebSourceProbe();web.vid=owner;web.book_id=target
            try:
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account();w=web.request('progress_after',WEB+'/web/book/getProgress?bookId='+target);web.verify_account();return n,w
            finally:web.close()
        phase='position';n,w=pair();p=state(w,target,sample['chapters'],'web')
        if p.get('kind')!='located' or p.get('chapter_uid')!=plan['chapter']:raise ValueError('cleanup/position')
        offset=p['chapter_offset'];expected=source_summary(FilteredSource(sample['source'],allow_multiple_bodies=True),offset)
        context=dict(pair=pair,plan=plan,sample=sample,target=target)
        baseline=verify_pair(context,offset,expected)
        if verify_pair(context,offset,expected)!=baseline:raise ValueError('cleanup/unstable')
        phase='notes';notes=ScopedNative(target,grant,owned,None).observe(grant)
        if notes['marks']['updated']!={} or notes['marks']['chapters']!={} or notes['thoughts']!={}:raise ValueError('cleanup/notes')
        latest_web=web_shelf();validate_fixture_shelf(latest_web,target)
        if not owned() or strip_fixture(latest_web,target)!=before:raise ValueError('cleanup/stale')
        latest_native=probe.shelf(grant);check_plan(upload['plan'],grant,latest_native,target,True);validate_fixture_shelf(latest_native,target)
        report.update(result='CLEANUP_PREVIEW_VERIFIED',fixture_bound=True,initial_slot_claimed=1,reconnect_slots_claimed=4,
                      source_and_dual_position_verified=True,reading_counters_unchanged=True,notes_empty=True,fixture_retained=True)
        if args.apply:
            phase='cleanup';report['result']='UNVERIFIED'
            def checked(plan,credentials,shelf,identity,present):
                check_plan(plan,credentials,shelf,identity,present)
                if present:validate_fixture_shelf(shelf,identity)
            if not cleanup_once(journal,receipt,upload['plan'],target,grant,probe,session_current,check=checked):raise ValueError('cleanup/unverified')
            phase='final_readback'
            if project(web_shelf())!=before or project(web_shelf())!=before:raise ValueError('cleanup/web_shelf')
            report.update(result='COMPLETED_FIXTURE_REMOVED',fixture_retained=False,original_native_shelf_restored=True,
                          original_web_shelf_restored=True,cleanup_acknowledged=True)
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',phase=phase)
        if str(error) in {'cleanup/target_flags','cleanup/group','cleanup/shelf','cleanup/scope','cleanup/source','personal_upload/changed','personal_upload/grant'}:report['detail']=str(error)
    finally:
        if probe:report['cleanup_posts']=probe.attempts['cleanup']
        if journal:
            try:
                value,_=journal.read();report['upload_state']=value['phase'] if value else 'absent'
                report['fixture_retained']=True if value and value['phase']=='imported' else False if value and value['phase']=='restored' else None
            except Exception:report['upload_state']='unknown'
        if source:source.samples.clear();source.close()
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result'] not in ('CLEANUP_PREVIEW_VERIFIED','COMPLETED_FIXTURE_REMOVED'))

if __name__=='__main__':raise SystemExit(main())
