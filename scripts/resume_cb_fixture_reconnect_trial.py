#!/usr/bin/env python3
"""Continue only an independently checked, zero-claim reconnect fixture.

The upload and first position are never replayed. Existing retained records
remain in Keychain, and ambiguous results block further writes or cleanup.
"""
import argparse
import hashlib
import json
import resource
from urllib.parse import urlencode

from cb_existing_position_intent import digest
from cb_fixture_position import plan as position_plan
from cloud_group_contract import project
from cloud_group_nonempty_workflow import strip_fixture
from reading_epub_trial import check as check_plan
from secure_native_session import NativeSessionStore
from secure_weread_session import ACCOUNT,SessionStore
from synthetic_upload_epub import TEXT
from verify_cb_fixture_highlight_trial import ScopedNative
from verify_cb_fixture_reconnect_trial import reconnect_trial,source_summary,stores,verify_pair
from verify_cb_initial_fixture_trial import NativeRead,SourceRead
from verify_cb_txt_manual_fixture_ui_trial import manual_command
from verify_eink_login import BASE as NATIVE
from verify_personal_upload_trial import Probe as UploadProbe,acknowledged,readback
from verify_source_coordinates import FilteredSource
from verify_web_source_progress import BASE as WEB,WebSourceProbe


def verify_intent(store,raw,owner,target,attempt,fingerprint,claimed):
    try:value=json.loads(raw)
    except (TypeError,ValueError,UnicodeError):raise ValueError('resume/intent') from None
    expected=dict(schema=1,scope=ACCOUNT,owner=digest(owner),book=digest(target),attempt=attempt,
                  baseline=fingerprint,claimed=claimed)
    if (not isinstance(value,dict) or type(value.get('schema')) is not int or type(value.get('claimed')) is not int
            or value!=expected or not store.verify(value,raw)):raise ValueError('resume/intent')
    return value


def read_source(owner,target,cookies,*,factory=SourceRead):
    """Use a fresh bounded reader each time; its read budget is one pass."""
    web=factory();web.vid=owner;web.book_id=target;web.allowed={target}
    try:
        for key,value in cookies.items():web.set_cookie(key,value)
        web.verify_account();sample=web.inspect(target);web.verify_account()
        if (sample['book_id']!=target or sample['source_format']!='web_xhtml' or TEXT not in sample['source']
                or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                or not all(web.last_checks.values())):raise ValueError('resume/source')
        return sample,web.catalog_versions
    finally:web.samples.clear();web.close()


def cleanup_once(journal,receipt,plan,target,grant,probe,current,*,check=check_plan,observe=readback):
    if not current():raise ValueError('resume/stale')
    check(plan,grant,probe.shelf(grant),target,True)
    receipt=journal.advance(receipt,'cleanup_pending')
    try:ack=acknowledged(probe.cleanup(grant,receipt))
    except Exception:ack=False
    restored=observe(probe,grant,plan,target,False,3 if ack else 1,__import__('time').sleep)
    if not ack or not restored:raise ValueError('resume/cleanup_unconfirmed')
    check(plan,grant,probe.shelf(grant),target,False)
    if not current():raise ValueError('resume/stale')
    journal.advance(receipt,'restored');return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--resume',action='store_true')
    args=parser.parse_args(argv)
    if args.saved_session!=args.resume:parser.error('both options are required')
    report=dict(result='OFFLINE_ONLY',account_data_writes_known=0,position_writes_known=0,position_writes_uncertain=False,
                cleanup_posts=0,authentication_posts=0,fixture_only=True,existing_book_writes=0,private_data_in_report=False)
    if not args.saved_session:print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None;phase='session';journal=probe=None
    try:
        session=SessionStore();saved=session.load();owner=saved['vid'];native_store=NativeSessionStore();grant=native_store.load(owner)
        journal,initial,manual=stores();upload,receipt=journal.read()
        if not upload or upload['phase']!='imported' or upload['plan']['owner']!=owner:raise ValueError('resume/scope')
        target=upload['target'];initial_raw=initial.backend.load();manual_raw=manual.backend.load()
        def session_current():return SessionStore().load()['vid']==owner and native_store.load(owner)==grant
        def owned():return session_current() and journal.read()==(upload,receipt) and initial.backend.load()==initial_raw
        probe=UploadProbe(journal,lambda value:session_current() and value==grant)
        phase='shelf';check_plan(upload['plan'],grant,probe.shelf(grant),target,True)
        def web_shelf():
            web=WebSourceProbe();web.vid=owner
            try:
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account();raw=web.request('shelf',WEB+'/web/shelf/sync');web.verify_account();return raw
            finally:web.close()
        def web_projection():return strip_fixture(web_shelf(),target)
        web_before=web_projection()
        if web_projection()!=web_before:raise ValueError('resume/shelf')
        def shelf_current():
            if not owned():return False
            check_plan(upload['plan'],grant,probe.shelf(grant),target,True)
            return web_projection()==web_before
        phase='source';sample,source_versions=read_source(owner,target,saved['cookies'])
        plan=position_plan(target,sample,require_unstarted=False)
        fingerprint=hashlib.sha256((sample['source_raw_sha256']+':'+str(plan['first'])).encode()).hexdigest()
        verify_intent(initial,initial_raw,owner,target,upload['attempt'],fingerprint,1)
        verify_intent(manual,manual_raw,owner,target,upload['attempt'],fingerprint,0)
        if not shelf_current():raise ValueError('resume/shelf')
        chapters=[]
        for row in sample['chapters']:
            item=dict(row)
            if type(item.get('wordCount')) not in (int,float) or item['wordCount']<=0:item['wordCount']=1000
            chapters.append(item)
        reader=NativeRead(grant,target)
        def pair():
            if not owned():raise ValueError('resume/stale')
            n=reader.request('first_progress',NATIVE+'/book/getProgress?'+urlencode(dict(bookId=target)),credentials=grant)
            web=WebSourceProbe();web.vid=owner;web.book_id=target
            try:
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account();w=web.request('progress_after',WEB+'/web/book/getProgress?bookId='+target);web.verify_account();return n,w
            finally:web.close()
        command=manual_command()
        context=dict(sample=sample,plan=plan,chapters=chapters,pair=pair,authority=owned,shelf_current=shelf_current,
                     cookies=lambda:saved['cookies'],owner=owner,attempt=upload['attempt'],source_hash=sample['source_raw_sha256'],
                     target=target,attest=lambda:command,command=command)
        phase='position';model=FilteredSource(sample['source'],allow_multiple_bodies=True);expected=source_summary(model,plan['first'])
        baseline=verify_pair(context,plan['first'],expected)
        if verify_pair(context,plan['first'],expected)!=baseline:raise ValueError('resume/unstable')
        context['initial_observed']=baseline
        phase='notes';notes=ScopedNative(target,grant,owned,None).observe(grant)
        if notes['marks']['updated']!={} or notes['marks']['chapters']!={} or notes['thoughts']!={}:raise ValueError('resume/notes')
        report.update(result='UNVERIFIED',fixture_bound=True,initial_position_confirmed=True,manual_slots_before=0)
        phase='native_reconnect';report['position_writes_uncertain']=True
        if not reconnect_trial(context,report,manual,command,resume=True):raise ValueError('resume/unverified')
        report['position_writes_uncertain']=False;report['account_data_writes_known']=report['position_writes_known']
        phase='source_after';later,later_versions=read_source(owner,target,saved['cookies'])
        if (later['source_raw_sha256']!=sample['source_raw_sha256'] or later['chapter_uid']!=sample['chapter_uid']
                or later['chapters']!=sample['chapters'] or later_versions!=source_versions
                or not shelf_current()):raise ValueError('resume/source_changed')
        if ScopedNative(target,grant,owned,None).observe(grant)['marks']!=notes['marks']:raise ValueError('resume/notes')
        if ScopedNative(target,grant,owned,None).observe(grant)['thoughts']!=notes['thoughts']:raise ValueError('resume/notes')
        phase='cleanup';report['account_data_writes_known']=None
        if not cleanup_once(journal,receipt,upload['plan'],target,grant,probe,session_current):raise ValueError('resume/cleanup_unconfirmed')
        report['cleanup_posts']=probe.attempts['cleanup'];report['account_data_writes_known']=report['position_writes_known']+report['cleanup_posts']
        if project(web_shelf())!=web_before:raise ValueError('resume/web_shelf')
        report.update(result='CB_FIXTURE_OFFLINE_RECONNECT_RESUMED',fixture_removed=True,web_shelf_restored=True,
                      original_native_shelf_restored=True,dual_readback=True,notes_unchanged=True)
    except (Exception,KeyboardInterrupt):report.update(result='UNVERIFIED',phase=phase)
    finally:
        if probe:report['cleanup_posts']=probe.attempts['cleanup']
        if journal:
            try:
                state,_=journal.read();report['upload_state']=state['phase'] if state else 'absent'
                report['fixture_retained']=True if state and state['phase']=='imported' else False if state and state['phase']=='restored' else None
            except Exception:report['upload_state']='unknown'
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result']!='CB_FIXTURE_OFFLINE_RECONNECT_RESUMED')

if __name__=='__main__':raise SystemExit(main())
