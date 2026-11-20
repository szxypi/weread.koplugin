#!/usr/bin/env python3
"""One new captured historical-window experiment, offline unless requested.

--saved-session is read-only. --apply uses the continuing development grant
for one durable claim and one POST. No renewal, fallback, capture edits, old
trial reuse, deletion of receipts or automatic replay. This is not a ledger UI.
"""
import argparse
import json,re,secrets,time
from annotation_experiment_model import digest
from cross_day_trial import TrialStore,bind,day,expected_months
from fetch_weread_epub import normalize_chapter_infos
from readtime_history_capture import CaptureStore
from readtime_upload_model import batch,confirmed,guest_token,integer,local_zone
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from selection_trial_probe import prepare_web_handoff
from verify_eink_login import BASE,NativeProbe,ProbeError
from verify_finish_roundtrip import point
from verify_native_statistics import period,project
from verify_owner_reading import reading_position
from verify_readtime_cross_day import Preflight
from verify_readtime_upload import counters
from verify_web_source_progress import BASE as WEB


class Trial(NativeProbe):
    def __init__(self,preflight=None,store=None,capture=None,opener=None,clock=time.time,sleep=time.sleep):
        super().__init__(opener);self.capture=capture or CaptureStore();self.preflight=preflight or Preflight(store=self.capture)
        self.source=self.preflight.source;self.store=store or TrialStore();self.clock,self.sleep=clock,sleep
        self.identity=self.grant=self.original=self.body=self.bound=self.receipt=None
        self.before=self.stats=self.inputs=None;self.months={};self.gets=self.posts=0;self.ack=False;self.target_reads=0

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if self.identity is None or credentials is None or digest(credentials)!=self.grant:raise ValueError('cross_upload/grant')
        if body is None:
            allowed={BASE+'/config?token=1',BASE+'/feature?synckey=0',BASE+'/book/info?bookId='+self.identity,
                     BASE+'/book/getProgress?bookId='+self.identity,*self.months.values()}
            if url not in allowed or self.gets>=40:raise ValueError('cross_upload/read_scope')
            self.gets+=1
        else:
            self.current(credentials);value,r=self.store.read()
            if (stage!='cross_day_dispatch' or url!=BASE+'/book/batchUploadProgress' or self.posts or body!=self.body
                    or value is None or value['phase']!='claimed' or value['plan']!=self.bound or r!=self.receipt):
                raise ValueError('cross_upload/write_scope')
            self.posts=1
        return super().request(stage,url,body=body,credentials=credentials,timeout=timeout)

    def current(self,credentials):
        self.source.current()
        if (self.original is None or self.capture.read()!=self.original or digest(credentials)!=self.grant
                or local_zone()!='+08:00' or not 0<=self.clock()-self.body['books'][0]['timestamp']<30
                or day(int(self.clock()))!=day(self.body['books'][0]['timestamp'])
                or self.source.plan.bound!=self.original[0]['plan']['source']):raise ValueError('cross_upload/changed')
        if (self.body!=batch(credentials,**self.inputs)
                or self.bound!=bind(self.original[0]['plan'],self.original[0],self.body,credentials,self.before,self.stats)):
            raise ValueError('cross_upload/changed')

    def version(self,credentials,stage):
        raw=self.request(stage,BASE+'/book/info?bookId='+self.identity,credentials=credentials)
        value=raw.get('bookVersion',raw.get('version'))
        if str(raw.get('bookId'))!=self.identity or not integer(value,1,2147483647) or value!=self.original[0]['plan']['book_version']:
            raise ValueError('cross_upload/version')

    def count(self,credentials,stage):
        raw=self.request(stage,BASE+'/book/getProgress?bookId='+self.identity,credentials=credentials);stamp=raw.get('timestamp')
        if not integer(stamp,1,4102444800) or abs(stamp-self.clock())>60 or stamp<self.original[0]['plan']['not_before']:
            raise ValueError('cross_upload/server_clock')
        if point(raw,self.identity)!=self.source.plan.baseline['position']:raise ValueError('cross_upload/position')
        return counters(raw,self.identity)

    def statistics(self,credentials,stage):
        result={}
        for key,url in self.months.items():
            raw=self.request(stage,url,credentials=credentials);value=project(raw,'monthly',int(key))
            result[key]={k:value[k] for k in ('baseTime','readTimes','totalReadTime','readDays')}
        return result

    def originals(self,credentials,stage):
        self.source.baseline(credentials,stage)
        if self.capture.read()!=self.original:raise ValueError('cross_upload/capture_replaced')

    def prepare(self,saved,credentials,on_final=None):
        if self.identity is not None or self.store.read()!=(None,None):raise ValueError('cross_upload/consumed')
        self.preflight.run(saved,credentials,on_final=on_final)
        self.original=self.capture.read();p=self.original[0]['plan']
        if p['time_zone']!='+08:00' or local_zone()!='+08:00':raise ValueError('cross_upload/zone')
        self.identity=p['source']['book_id'];self.grant=digest(credentials)
        self.months={str(period('monthly',stamp)[0]):BASE+'/readdata/detail?mode=monthly&baseTime='+str(period('monthly',stamp)[0])
                     for stamp in (p['start_time'],int(self.clock()))}
        config=self.request('cross_upload_config',BASE+'/config?token=1',credentials=credentials)
        guest,_kind=guest_token(self.request('cross_upload_feature',BASE+'/feature?synckey=0',credentials=credentials))
        self.version(credentials,'cross_upload_version_before');self.before=self.count(credentials,'cross_upload_count_before')
        if not integer(self.before['readingTime'],0,2**53-3):raise ValueError('cross_upload/counter_limit')
        self.stats=self.statistics(credentials,'cross_upload_statistics_before');self.originals(credentials,'cross_upload_originals_before')
        stamp=int(self.clock()*1000);now=stamp//1000
        self.inputs=dict(book_id=self.identity,rows=[{k:p[k] for k in ('start_time','duration','time_zone','book_version')}],
            guest=guest,config_token=config.get('token'),now=now,random=secrets.randbelow(1000),outer_timestamp=stamp,
            outer_random=secrets.randbelow(1000),current_zone='+08:00')
        self.body=batch(credentials,**self.inputs)
        self.bound=bind(p,self.original[0],self.body,credentials,self.before,self.stats)
        self.expected=expected_months(self.stats,p,now);self.current(credentials)

    def final_source(self,credentials):
        self.originals(credentials,'cross_upload_final_originals');self.version(credentials,'cross_upload_version_after')
        catalog,chapters=normalize_chapter_infos(self.source.web.request('catalog_after',WEB+'/web/book/chapterInfos',dict(bookIds=[self.identity])),self.identity)
        book=catalog.get('book',{});version=book.get('bookVersion',book.get('version')) if isinstance(book,dict) else None
        if not integer(version,1,2147483647) or version!=self.original[0]['plan']['book_version'] or chapters!=self.source.plan.chapters:
            raise ValueError('cross_upload/catalog')
        self.source.web.verify_account()
        if reading_position(self.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+self.identity),self.identity)!=self.source.plan.web_position:
            raise ValueError('cross_upload/web_position')

    def run(self,credentials,*,apply=False,on_final=None):
        if type(apply) is not bool:raise ValueError('cross_upload/mode')
        self.current(credentials)
        if self.store.read()!=(None,None):raise ValueError('cross_upload/consumed')
        self.originals(credentials,'cross_upload_originals_final_preflight');self.version(credentials,'cross_upload_version_final_preflight')
        if self.count(credentials,'cross_upload_count_final_preflight')!=self.before or self.statistics(credentials,'cross_upload_stats_final_preflight')!=self.stats:
            raise ValueError('cross_upload/concurrent_before')
        if apply:
            self.current(credentials);self.receipt=self.store.reserve(self.bound);self.receipt=self.store.advance(self.receipt,'prepared','claimed')
            try:self.ack=confirmed(self.request('cross_day_dispatch',BASE+'/book/batchUploadProgress',body=self.body,credentials=credentials,timeout=20))
            except ProbeError:pass
            if self.ack:self.receipt=self.store.advance(self.receipt,'claimed','acknowledged')
            target=dict(self.before,readingTime=self.before['readingTime']+2);consecutive=0;seen_target=False
            for attempt in range(4 if self.ack else 1):
                if attempt:self.sleep(min(5,attempt*2))
                if day(int(self.clock()))!=day(self.bound['created_at']):raise ValueError('cross_upload/day_changed')
                self.originals(credentials,'cross_upload_readback_originals')
                count=self.count(credentials,'cross_upload_readback_count');stats=self.statistics(credentials,'cross_upload_readback_statistics')
                if count not in (self.before,target) or stats not in (self.stats,*self.expected):raise ValueError('cross_upload/unrelated_delta')
                matched=count==target and stats in self.expected
                if seen_target and not matched:raise ValueError('cross_upload/regressed_readback')
                if matched:
                    seen_target=True;consecutive+=1;self.target_reads+=1
                    month=str(period('monthly',self.original[0]['plan']['start_time'])[0])
                    self.read_days_delta=stats[month]['readDays']-self.stats[month]['readDays']
                if consecutive==2:break
            if not self.ack or consecutive!=2:raise ValueError('cross_upload/not_confirmed')
        self.final_source(credentials)
        if on_final:on_final()
        if self.capture.read()!=self.original:raise ValueError('cross_upload/capture_replaced')
        if day(int(self.clock()))!=day(self.bound['created_at']):raise ValueError('cross_upload/day_changed')
        if apply:
            self.receipt=self.store.advance(self.receipt,'acknowledged','verified')
            self.receipt=self.store.advance(self.receipt,'verified','retired')
        return dict(result='PASS_HISTORICAL_ACCOUNTING' if apply else 'PASS_READONLY',account_data_posts=self.posts,authentication_posts=0,
            controlled_test_seconds=2,historical_accounting_verified=apply,explicit_success_receipt=self.ack,
            independent_target_reads=self.target_reads,historical_day_delta=2 if apply else 0,current_day_delta=0,
            book_reading_time_delta=2 if apply else 0,other_counters_and_buckets_unchanged=True,
            original_positions_records_catalog_version_exact=True,capture_unchanged=True,old_request_replayed=False,
            scope_retained=apply,read_days_delta=getattr(self,'read_days_delta',0))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');mode=parser.add_mutually_exclusive_group()
    mode.add_argument('--apply',action='store_true');mode.add_argument('--status',action='store_true');args=parser.parse_args(argv)
    result=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,historical_accounting_verified=False);probe=saved=credentials=None
    try:
        if args.saved_session:
            store=TrialStore()
            if args.status:
                value,_r=store.read();result.update(result='PASS',scope_phase=value['phase'] if value else 'absent')
            else:
                from verify_native_thought_trial import other_pending
                from secure_native_thought_trial import NativeThoughtTrialStore
                from secure_selection_trial import SelectionTrialStore
                if other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('cross_upload/other_pending')
                session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid']);probe=Trial(store=store)
                def handoff():
                    nonlocal saved
                    saved=prepare_web_handoff(session,saved,probe.source)
                probe.prepare(saved,credentials,on_final=handoff)
                result=probe.run(credentials,apply=args.apply,on_final=handoff)
        elif args.apply or args.status:raise ValueError('cross_upload/offline')
    except (Exception,KeyboardInterrupt) as error:
        result.update(result='UNVERIFIED')
        if isinstance(error,ValueError) and re.fullmatch(r'(?:cross_upload|cross_trial|cross_day|selection_trial)/[a-z_]{1,64}',str(error)):result['reason']=str(error)
    finally:
        if probe:
            result.update(account_data_posts=probe.posts,explicit_success_receipt=probe.ack,independent_target_reads=probe.target_reads)
            result['stages']={name:[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in transport.report['stages']]
                for name,transport in (('native',probe),('preflight',probe.preflight),('source_native',probe.source.notes),('source_web',probe.source.web))}
            value,_r=probe.store.read();result['scope_phase']=value['phase'] if value else 'absent'
            probe.source.web.shards.clear();probe.source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(result,indent=2));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
