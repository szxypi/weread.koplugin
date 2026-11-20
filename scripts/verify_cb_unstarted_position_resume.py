#!/usr/bin/env python3
"""Resume the already-imported unstarted/time fixture, never resend its time.

Offline by default. A dry run blocks position writes in memory. Apply repeats
that preflight, then claims exactly one new position request. A mismatch or
unknown response retains the book; cleanup is separately claimed and not retried.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import resource
import time
from urllib.parse import urlencode

from cb_cloud_position import observed
from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from cloud_group_contract import project
from cloud_group_nonempty_workflow import strip_fixture
from personal_upload_trial import hash_value
from secure_native_session import NativeSessionStore
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT, SessionStore
from verify_cb_fixture_position_trial import owned
from verify_cb_fixture_web_time import NativeRead
from verify_cb_full_summary_payload import compare
from verify_cb_reading import CbReadingProbe
from verify_cb_txt_fixture import MARKER, check_plan
from verify_cb_txt_version_fixture import inspect_fixture
from verify_cb_unstarted_position_fixture import PositionProbe, position_trial, stores
from verify_personal_upload_trial import Probe as UploadProbe, acknowledged, readback
from verify_reader_progress import find_node
from verify_readtime_upload import expected_statistics
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, WebSourceProbe


class Memory:
    def __init__(self): self.value=None
    def load(self): return self.value
    def save(self, value): self.value=value


class BlockedPositionProbe(PositionProbe):
    denied=0
    def send_once(self, _body, _permit, _reservation):
        self.denied+=1
        raise ValueError('unstarted_resume/write_blocked')


def verify_records(record, owner, grant, time_intent, evidence_raw, target_receipt, position_intent, position_evidence):
    if (not isinstance(record,dict) or record.get('phase')!='imported' or record['plan'].get('owner')!=owner
            or record['plan'].get('grant_sha256')!=hash_value(grant) or position_intent.backend.load() is not None
            or position_evidence.backend.load() is not None): raise ValueError('unstarted_resume/record')
    target,attempt=record['target'],record['attempt']
    expected=canonical(dict(schema=1,owner=owner,attempt=attempt,target=target,plan_sha256=hash_value(record['plan'])))
    if target_receipt.backend.load()!=expected or not isinstance(evidence_raw,bytes): raise ValueError('unstarted_resume/receipt')
    evidence=json.loads(evidence_raw); raw=time_intent.backend.load(); claimed=json.loads(raw) if raw else None
    if (not isinstance(evidence,dict) or set(evidence)!={'schema','owner_sha256','book_sha256','attempt','baseline'}
            or evidence['schema']!=1 or evidence['owner_sha256']!=hashlib.sha256(owner.encode()).hexdigest()
            or evidence['book_sha256']!=hashlib.sha256(target.encode()).hexdigest() or evidence['attempt']!=attempt
            or not isinstance(claimed,dict) or claimed.get('scope')!=ACCOUNT or claimed.get('claimed') is not True
            or claimed.get('owner')!=evidence['owner_sha256'] or claimed.get('book')!=evidence['book_sha256']
            or claimed.get('attempt')!=attempt or claimed.get('baseline')!=hashlib.sha256(canonical(evidence['baseline'])).hexdigest()
            or not time_intent.verify(claimed,raw)):
        raise ValueError('unstarted_resume/time_record')
    baseline=evidence['baseline'];body=baseline.get('body');books=body.get('books') if isinstance(body,dict) else None
    if (not isinstance(books,list) or len(books)!=1 or not isinstance(books[0],dict)
            or books[0].get('bookId')!=target or books[0].get('bookVersion')!=0
            or books[0].get('readingTime')!=2 or books[0].get('summary')!=''
            or books[0].get('isResendReadingInfo')!=1 or baseline.get('counters')!=dict(readingTime=0,recordReadingTime=0,ttsTime=0)):
        raise ValueError('unstarted_resume/time_body')
    return evidence,claimed,raw


def lua_check(plan,summary,payload,command):
    options=dict(book_id=plan['book'],chapter_uid=plan['chapter'],chapter_idx=plan['index'],chapter_offset=plan['first'],
                 progress=plan['percent'],summary=summary,psvts=plan['psvts'],pclts=plan['pclts'],token=plan['token'],now=payload['ct'])
    return compare([dict(stage='enter',options=options,expected=payload)],command)


def run(saved,session,native,grant,journal,receipt,time_intent,time_evidence,position_intent,position_evidence,*,apply=False,
        position=position_trial, upload_factory=UploadProbe, sleep=time.sleep, lua_command=None):
    report=dict(result='UNVERIFIED',phase='preflight',time_posts=0,position_posts=0,cleanup_posts=0,
                position_write_uncertain=False,cleanup_uncertain=False,authentication_posts=0,existing_book_writes=0,
                fixture_only=True,private_data_in_report=False)
    current={'saved':saved}; api_box={}; phase='preflight'; probe=None
    try:
        record,journal_receipt=journal.read();owner=saved['vid']
        phase='records'
        evidence_raw=time_evidence.backend.load()
        evidence,time_record,time_raw=verify_records(record,owner,grant,time_intent,evidence_raw,
                                                     receipt,position_intent,position_evidence)
        target=record['target'];attempt=record['attempt'];baseline=evidence['baseline']
        def same_grant(value):return native.load(owner)==value
        expected_receipt=canonical(dict(schema=1,owner=owner,attempt=attempt,target=target,plan_sha256=hash_value(record['plan'])))
        def authority():
            return (owned(journal,journal_receipt,target,owner,grant,same_grant) and receipt.backend.load()==expected_receipt
                    and time_intent.verify(time_record,time_raw) and time_evidence.backend.load()==evidence_raw)
        def persist(web):
            if web.authenticated and save_refreshed_web_session(session,current['saved'],web):
                old=current['saved'];current['saved']=session.load()
                if old['vid']!=current['saved']['vid']:raise ValueError('unstarted_resume/owner')
                old.clear()
        def connect(cls,book=None):
            web=cls();web.vid=owner
            if book:
                web.book_id=book
                if hasattr(web,'allowed'):web.allowed={book}
            for key,value in current['saved']['cookies'].items():web.set_cookie(key,value)
            web.verify_account();return web
        def shelf(present=True):
            web=connect(WebSourceProbe)
            try:
                raw=web.request('shelf',BASE+'/web/shelf/sync')
                value=strip_fixture(raw,target) if present else project(raw)
                web.verify_account();persist(web);return value
            finally:web.close()
        if not authority():raise ValueError('unstarted_resume/owner')
        phase='native_shelf'
        probe=upload_factory(journal,same_grant)
        check_plan(record['plan'],grant,probe.shelf(grant),target,True)
        check_plan(record['plan'],grant,probe.shelf(grant),target,True)
        phase='web_shelf'
        web_shelf=shelf()
        if shelf()!=web_shelf:raise ValueError('unstarted_resume/shelf')
        phase='source'
        web=connect(CbReadingProbe,target)
        try:
            sample=web.inspect(target);web.verify_account()
            if (sample.get('source_raw_sha256')!=baseline['source'] or sample.get('source_format')!='web_txt'
                    or sample.get('book_id')!=target or MARKER not in sample.get('source','')
                    or not all(web.last_checks.get(k) is True for k in ('catalog_unchanged','versions_unchanged','position_unchanged'))):
                raise ValueError('unstarted_resume/source')
            persist(web)
        finally:web.samples.clear();web.close()
        phase='version'
        info={};view=dict(vid=owner,cookies=current['saved']['cookies'])
        if (not inspect_fixture(view,grant,target,lambda value:authority() and value==grant,info,expected_source=baseline['source'])
                or info.get('native_version_category')!='zero'
                or any(info.get(k)!='absent' for k in ('catalog_root_version_category','catalog_book_version_category'))):
            raise ValueError('unstarted_resume/version')
        phase='statistics_plan'
        body=baseline['body']['books'][0];stamp=body['timestamp'];zone=body['recordCreateTimeZone'];old_stats=baseline['stats']
        alternatives=[]
        for delta in (0,1):
            value=expected_statistics(old_stats,stamp,2,time_zone=zone);value['readDays']=old_stats['readDays']+delta;alternatives.append(value)
        api_box['value']=NativeRead(grant,target)
        def stats():
            value=api_box['value'].stats()
            if value not in alternatives:raise ValueError('unstarted_resume/statistics')
            return value
        latest={}
        def pair():
            if not authority():raise ValueError('unstarted_resume/owner')
            web=connect(WebSourceProbe,target)
            try:
                n=api_box['value'].progress();w=web.request('progress_after',BASE+'/web/book/getProgress?'+urlencode({'bookId':target}))
                updated=find_node(w,target).get('updateTime')
                if type(updated) is not int or updated<0:raise ValueError('unstarted_resume/updated')
                latest['updated']=updated;web.verify_account();persist(web)
                return {c:observed(raw,target,sample['chapters'],c) for c,raw in (('native',n),('web',w))}
            finally:web.close()
        def check_initial():
            value=pair()
            for channel in ('native','web'):
                p=value[channel]
                if (p['state'].get('kind')!='no_chapter' or any(p['counters'][k]!={'present':True,'value':v}
                        for k,v in (('readingTime',2),('recordReadingTime',0),('ttsTime',0)))):
                    raise ValueError('unstarted_resume/position')
            if value['web']['projection']!=baseline['position']:raise ValueError('unstarted_resume/position')
            return value
        phase='time_readback'
        first=check_initial()
        if check_initial()!=first or stats()!=stats():raise ValueError('unstarted_resume/unstable')
        context=dict(owner=owner,target=target,attempt=attempt,sample=sample,source_hash=baseline['source'],pair=pair,stats=stats,
                     authority=authority,shelf_current=lambda:shelf()==web_shelf,connect=connect,persist=persist,
                     cookies=lambda:current['saved']['cookies'],latest=latest)
        if not lua_command:raise ValueError('unstarted_resume/lua')
        compare_payload=lambda p,s,v:lua_check(p,s,v,lua_command)
        dry_report={};phase='dry_run'
        dry=position(context,dry_report,Intent(backend=Memory()),Evidence(backend=Memory()),
                     probe_factory=BlockedPositionProbe,sleep=lambda _:None,payload_check=compare_payload)
        if (dry.get('attempted')!=1 or dry.get('acknowledged') is not False or dry.get('cleanup_allowed') is not False
                or dry_report.get('position_posts')!=0 or position_intent.backend.load() is not None
                or position_evidence.backend.load() is not None):raise ValueError('unstarted_resume/dry_run')
        if check_initial()!=first or not authority() or shelf()!=web_shelf:raise ValueError('unstarted_resume/changed')
        report.update(result='READ_ONLY_PREVIEW',phase='preview',write_blocked=True,lua_payload_matches=True,
                      original_time_verified=True,fixture_present=True)
        if not apply:return report
        api_box['value']=NativeRead(grant,target);phase='position';report.update(result='UNVERIFIED',phase=phase)
        actual=position(context,report,position_intent,position_evidence,sleep=sleep,payload_check=compare_payload)
        report['position_probe']=actual;report['position_posts']=actual['attempted']
        report['position_write_uncertain']=actual['write_uncertain']
        if actual.get('result')!='PASS' or not actual.get('cleanup_allowed') or not authority():
            raise ValueError('unstarted_resume/unconfirmed')
        if shelf()!=web_shelf:raise ValueError('unstarted_resume/shelf')
        check_plan(record['plan'],grant,probe.shelf(grant),target,True)
        check_plan(record['plan'],grant,probe.shelf(grant),target,True)
        if not authority():raise ValueError('unstarted_resume/owner')
        journal_receipt=journal.advance(journal_receipt,'cleanup_pending');phase='cleanup';report.update(phase=phase,cleanup_uncertain=True)
        ack=False
        try:ack=acknowledged(probe.cleanup(grant,journal_receipt))
        finally:report['cleanup_posts']=probe.attempts['cleanup']
        restored=readback(probe,grant,record['plan'],target,False,3 if ack else 1,sleep)
        if not ack or not restored:raise ValueError('unstarted_resume/cleanup')
        check_plan(record['plan'],grant,probe.shelf(grant),target,False)
        if shelf(False)!=web_shelf:raise ValueError('unstarted_resume/shelf')
        journal.advance(journal_receipt,'restored')
        report.update(result='FIRST_POSITION_WITH_TIME_VERIFIED',phase='restored',cleanup_uncertain=False,
                      fixture_present=False,original_shelf_restored=True)
    except Exception as error:
        import traceback
        frames=traceback.extract_tb(error.__traceback__)
        report['result']='UNVERIFIED';report['phase']=phase
        report['failure_type']=type(error).__name__
        if frames:report['failure_function']=frames[-1].name;report['failure_line']=frames[-1].lineno
        # A claimed position record can exist even if the process failed before
        # reporting the dispatch count; never report zero in that case.
        if phase=='position' and position_intent.backend.load() is not None and 'position_probe' not in report:
            report['position_posts']=None;report['position_write_uncertain']=True
    finally:
        if current['saved'] is not saved and saved:saved.clear()
        if current['saved']:current['saved'].clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',time_posts=0,position_posts=0,cleanup_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        command=['docker','exec','-i','-w','/validation/runtime/lib/koreader','weread-validation','./luajit',
                 '/source/spec/koreader/cb_full_summary_payload_probe.lua','/source']
        result=run(saved,session,native,grant,*stores(),apply=args.apply,lua_command=command)
    except Exception:
        result=dict(result='UNVERIFIED',phase='unknown' if args.apply else 'preflight',time_posts=0,
                    position_posts=None if args.apply else 0,cleanup_posts=None if args.apply else 0,
                    position_write_uncertain=args.apply,cleanup_uncertain=args.apply)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(result));return int(result['result'] not in ('READ_ONLY_PREVIEW','FIRST_POSITION_WITH_TIME_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
