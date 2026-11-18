#!/usr/bin/env python3
"""Verify one two-second native time-only report on a newly imported self-authored book.

Offline by default. Apply binds the fixture, source, preflight statistics and
exact request to new single-use records. Only one nonzero report can be sent.
An uncertain result prevents replay and automatic removal of the fixture.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import resource
import tempfile
import time
import secrets
from urllib.parse import urlencode

from cb_cloud_position import state
from cb_fixture_position import plan as position_plan
from cb_fixture_position_intent import Intent as SeedIntent
from cb_fixture_position_transport import Probe as SeedProbe
from cb_native_readtime_model import batch as build_batch
from readtime_upload_model import confirmed,guest_token
from fetch_weread_epub import normalize_chapter_infos
from cb_fixture_web_time_intent import Intent as TimeIntent
from readtime_upload_model import local_zone
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_cloud_position import Web
from verify_cb_fixture_position_trial import owned
from verify_cb_reading import CbReadingProbe
from verify_eink_login import BASE as NATIVE,NativeProbe
from verify_native_statistics import period
from verify_personal_upload_trial import Probe as UploadProbe
from verify_position_roundtrip import canonical
from verify_reader_progress import find_node
from verify_readtime_upload import counters,expected_statistics,statistics
from verify_synthetic_epub_upload import run as run_upload
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe

UPLOAD_SERVICE='org.codex.weread.cb-native-batch-fixture-upload-v1'
SEED_SERVICE='org.codex.weread.cb-native-batch-fixture-seed-v1'
TIME_SERVICE='org.codex.weread.cb-native-batch-fixture-send-v1'


def backend(service):return MacKeychain(service=service,account=ACCOUNT)
def lock(name):
    path=Path(tempfile.gettempdir())/('codex-cb-native-batch-fixture-'+name+'-'+ACCOUNT+'.lock')
    return lambda:project_lock(path)
def stores():
    return (Journal(backend=backend(UPLOAD_SERVICE),lock=lock('upload')),
            SeedIntent(backend=backend(SEED_SERVICE),lock=lock('seed')),
            TimeIntent(backend=backend(TIME_SERVICE),lock=lock('time')))


def position(raw,book,chapters,channel='web'):
    value=state(raw,book,chapters,channel)
    if value.get('kind')!='located' or not value.get('summary_present'):raise ValueError('cb_time/position')
    return {key:value[key] for key in ('chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')}


class NativeRead(NativeProbe):
    def __init__(self,credentials,book):
        super().__init__();self.credentials=credentials;self.book=book;self.reads=0
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed={NATIVE+'/book/getProgress?'+urlencode({'bookId':self.book}),
                 NATIVE+'/readdata/detail?mode=monthly&baseTime=0'}
        if body is not None or credentials!=self.credentials or url not in allowed or self.reads>=30:
            raise ValueError('cb_time/native_scope')
        self.reads+=1;return super().request(stage,url,credentials=credentials,timeout=timeout)
    def progress(self):return self.request('time_progress',NATIVE+'/book/getProgress?'+urlencode({'bookId':self.book}),credentials=self.credentials)
    def stats(self):return statistics(self.request('time_stats',NATIVE+'/readdata/detail?mode=monthly&baseTime=0',credentials=self.credentials),int(time.time()))


class BatchProbe(NativeRead):
    def __init__(self,credentials,book):
        super().__init__(credentials,book);self.expected=None;self.sent=0
    def info(self):
        return NativeProbe.request(self,'batch_info',NATIVE+'/book/info?'+urlencode({'bookId':self.book}),credentials=self.credentials)
    def config(self):return NativeProbe.request(self,'batch_config',NATIVE+'/config?token=1',credentials=self.credentials)
    def feature(self):return NativeProbe.request(self,'batch_feature',NATIVE+'/feature?synckey=0',credentials=self.credentials)
    def send_once(self,value,authority):
        if self.sent or not authority() or not isinstance(value,dict) or len(value.get('books',[]))!=1:
            raise ValueError('cb_batch/scope')
        book=value['books'][0]
        if (book.get('bookId')!=self.book or book.get('readingTime')!=2 or book.get('isResendReadingInfo')!=1
                or type(book.get('timestamp')) is not int or not 0<=time.time()-book['timestamp']<30
                or sum(hour.get('readingTime',0) for hour in book.get('hours',[]))!=2):raise ValueError('cb_batch/body')
        self.expected=deepcopy(value);self.sent=1
        if not authority() or value!=self.expected:raise ValueError('cb_batch/changed')
        return NativeProbe.request(self,'batch_write',NATIVE+'/book/batchUploadProgress',body=value,credentials=self.credentials,timeout=20)


def run(saved,session,native,grant,journal,seed_intent,time_intent,*,evidence=None,apply=False,upload_factory=UploadProbe,upload_run=run_upload):
    report=dict(result='UNVERIFIED',phase='preflight',account_data_writes=0,authentication_writes=0,
        fixture_only=True,existing_book_writes=0,positive_time_posts=0,private_data_in_report=False)
    current={'saved':saved,'plan':None,'source_hash':None}
    def same_grant(value):return native.load(current['saved']['vid'])==value
    def persist(probe):
        if probe.authenticated and save_refreshed_web_session(session,current['saved'],probe):
            previous=current['saved'];current['saved']=session.load()
            if current['saved']['vid']!=previous['vid']:raise ValueError('cb_time/owner')
            previous.clear()
    def connect(cls,target,*args):
        probe=cls(*args) if args else cls();probe.vid=current['saved']['vid']
        if hasattr(probe,'allowed'):probe.allowed={target}
        for key,value in current['saved']['cookies'].items():probe.set_cookie(key,value)
        probe.verify_account();return probe
    def read_source(target):
        web=connect(CbReadingProbe,target)
        try:
            sample=web.inspect(target);web.verify_account()
            if not (sample['book_id']==target and sample['source_format']=='web_xhtml' and TEXT in sample['source']
                    and set(web.last_checks)=={'catalog_unchanged','versions_unchanged','position_unchanged'}
                    and all(value is True for value in web.last_checks.values())):return False
            current['plan']=position_plan(target,sample);current['source_hash']=sample['source_raw_sha256'];return True
        finally:persist(web);web.samples.clear();web.close()
    def trial(upload_journal,receipt,_upload_plan,target):
        report['time_phase']='fixture'
        if current['plan'] is None:return True
        owner=current['saved']['vid']
        if not owned(upload_journal,receipt,target,owner,grant,same_grant):return False
        state_,_=upload_journal.read();attempt=state_['attempt'];seed_receipt=seed_intent.reserve(owner,target,attempt)
        def seed_authority():
            return owned(upload_journal,receipt,target,owner,grant,same_grant) and seed_intent.verify(seed_receipt,owner,target,attempt)
        seed=SeedProbe(current['plan'],owner,seed_authority)
        try:
            for key,value in current['saved']['cookies'].items():seed.set_cookie(key,value)
            seed.verify_account();seed_result=seed.execute(dict(chapter_uid=0,chapter_offset=0,raw_percent=0))
            report['account_data_writes']+=seed_result['writes']
            if seed_result['result']!='PASS':return False
        finally:persist(seed);seed.close()
        report['time_phase']='source'
        source=connect(Web,target)
        try:
            report['time_phase']='baseline'
            sample=source.inspect(target);raw=source.progress[(target,'progress_before')]
            if sample['source_raw_sha256']!=current['source_hash'] or sample['chapter_uid']!=current['plan']['chapter']:
                return False
            chapters=sample['chapters'];before_position=position(raw,target,chapters)
            if before_position['chapter_offset']!=current['plan']['first']:return False
            baseline_stamp=find_node(raw,target).get('updateTime')
            if type(baseline_stamp) is not int or baseline_stamp<0:return False
            source.verify_account();persist(source)
        finally:source.samples.clear();source.progress.clear();source.close()
        api=BatchProbe(grant,target)
        web=connect(WebSourceProbe,target)
        web.book_id=target;web.chapter=current['plan']['chapter']
        try:
            native_before=api.progress();before_counts=counters(native_before,target);before_stats=api.stats()
            if position(native_before,target,chapters,'native')!=before_position:return False
            web_before=web.request('progress_before',BASE+'/web/book/getProgress?'+urlencode({'bookId':target}))
            if (position(web_before,target,chapters)!=before_position or counters(web_before,target)!=before_counts
                    or find_node(web_before,target).get('updateTime')!=baseline_stamp):return False
            info=api.info();version=info.get('bookVersion',info.get('version'))
            catalog_raw=web.request('catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[target]})
            catalog,_=normalize_chapter_infos(catalog_raw,target);versions=[]
            for node in (catalog,catalog.get('book',{})):
                if isinstance(node,dict):
                    for key in ('bookVersion','version'):
                        if key in node:versions.append(node[key])
            if (str(info.get('bookId'))!=target or type(version) is not int or not 1<=version<=2147483647
                    or not versions or any(type(value) is not int or value!=version for value in versions)):return False
            config=api.config();guest,_kind=guest_token(api.feature())
            wall=time.time();mono=time.monotonic();start=math.ceil(wall);time.sleep(max(0,start+2-wall)+.01)
            report['time_phase']='window'
            if not 2<=time.monotonic()-mono<=4 or not 0<=time.time()-(start+2)<2:return False
            native_final=api.progress()
            if (api.stats()!=before_stats or counters(native_final,target)!=before_counts
                    or position(native_final,target,chapters,'native')!=before_position):return False
            web_final=web.request('progress_before',BASE+'/web/book/getProgress?'+urlencode({'bookId':target}))
            if (position(web_final,target,chapters)!=before_position or counters(web_final,target)!=before_counts
                    or find_node(web_final,target).get('updateTime')!=baseline_stamp):return False
            now=int(time.time());rows=[dict(start_time=start,duration=2,time_zone=local_zone(),book_version=version)]
            if now<start+2 or now>start+3:return False
            payload=build_batch(grant,target,rows,guest,config.get('token'),now,secrets.randbelow(1000),now*1000,secrets.randbelow(1000),current_zone=local_zone())
            if period('monthly',start)[0]!=period('monthly',now)[0]:return False
            candidates=[]
            for zone in ('+08:00',local_zone()):
                for delta in (0,1):
                    candidate=expected_statistics(before_stats,start,2,time_zone=zone)
                    candidate['readDays']=before_stats['readDays']+delta;candidates.append(candidate)
            baseline=dict(source=current['source_hash'],position=before_position,updated_at=baseline_stamp,
                          counters=before_counts,stats=before_stats,body=payload)
            baseline_hash=hashlib.sha256(canonical(baseline).encode()).hexdigest()
            if evidence is None:return False
            evidence.save(dict(schema=1,owner_sha256=hashlib.sha256(owner.encode()).hexdigest(),
                book_sha256=hashlib.sha256(target.encode()).hexdigest(),attempt=attempt,baseline=baseline))
            report['baseline_saved']=True
            reservation=time_intent.reserve(owner,target,attempt,baseline_hash)
            claim=time_intent.claim(reservation)
            if not seed_authority() or not time_intent.verify(reservation,claim):return False
            report['time_phase']='dispatch'
            try:
                accepted=confirmed(api.send_once(payload,lambda:seed_authority() and time_intent.verify(reservation,claim)))
            finally:report['positive_time_posts']=api.sent;report['account_data_writes']+=api.sent
            report['positive_time_acknowledged']=accepted
            if not accepted:return False
            report['time_phase']='readback'
            expected_counts=dict(before_counts,readingTime=before_counts['readingTime']+2)
            matched=False
            for index in range(4):
                if index:time.sleep(min(index*2,5))
                n=api.progress();s=api.stats();w=web.request('progress_after',BASE+'/web/book/getProgress?'+urlencode({'bookId':target}))
                web_same=position(w,target,chapters)==before_position
                native_same=position(n,target,chapters,'native')==before_position
                nc,wc=counters(n,target),counters(w,target)
                report['readback']=dict(web_position_same=web_same,native_position_same=native_same,
                    native_seconds_delta=nc['readingTime']-before_counts['readingTime'],
                    web_seconds_delta=wc['readingTime']-before_counts['readingTime'],
                    other_native_counters_same=all(nc[k]==before_counts[k] for k in ('recordReadingTime','ttsTime')),
                    other_web_counters_same=all(wc[k]==before_counts[k] for k in ('recordReadingTime','ttsTime')),
                    monthly_seconds_delta=s['totalReadTime']-before_stats['totalReadTime'],
                    days_delta=s['readDays']-before_stats['readDays'],statistics_match=s in candidates)
                if not web_same or not native_same:return False
                if nc not in (before_counts,expected_counts) or wc not in (before_counts,expected_counts):return False
                if s not in [before_stats,*candidates]:return False
                if nc==expected_counts and wc==expected_counts and s in candidates:matched=True;break
            if not matched:return False
            web.verify_account();persist(web)
            report.update(positive_time_acknowledged=True,book_counter_delta=2,monthly_total_delta=2,daily_bucket_delta=2,
                source_position_unchanged=True,no_replay=True,time_phase='confirmed')
            return seed_authority() and time_intent.verify(reservation,claim)
        finally:web.close()
    try:
        if seed_intent.backend.load() is not None or time_intent.backend.load() is not None:raise ValueError('cb_time/already_reserved')
        web=connect(CbReadingProbe,None)
        try:web.verify_account();persist(web)
        finally:web.close()
        upload=upload_factory(journal,same_grant)
        result=upload_run(upload,journal,grant,same_grant,read_source,apply=apply,cleanup_gate=trial)
        report['upload']=result;report['phase']=result.get('phase','unknown')
        report['account_data_writes']+=result.get('cos_put_attempts',0)+result.get('notify_posts',0)+result.get('cleanup_posts',0)
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='EPUB_IMPORT_AND_SOURCE_VERIFIED' and report.get('positive_time_acknowledged'):
            report['result']='FIXTURE_NATIVE_BATCH_VERIFIED'
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        current['plan']=None
        if current['saved'] is not saved and saved:saved.clear()
        if current['saved']:current['saved'].clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        from cb_fixture_web_time_evidence import Evidence
        report=run(saved,session,native,grant,*stores(),evidence=Evidence(backend=backend('org.codex.weread.cb-native-batch-fixture-baseline-v1'),lock=lock('baseline')),apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',account_data_writes=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_PREVIEW','FIXTURE_NATIVE_BATCH_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
