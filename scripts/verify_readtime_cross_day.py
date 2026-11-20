#!/usr/bin/env python3
"""Read-only fresh preflight for the immutable real cross-day capture.

No payload creation, claim, upload, renewal or timestamp edits. A successful
preflight is not a dispatch grant and is never a historical accounting proof.
"""
import argparse
import json,re,time
from annotation_experiment_model import digest
from fetch_weread_epub import normalize_chapter_infos
from readtime_history_capture import CaptureStore,validate
from readtime_upload_model import integer
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from selection_trial_probe import SelectionProbe,prepare_web_handoff
from verify_eink_login import NativeProbe,BASE
from verify_finish_roundtrip import point
from verify_native_statistics import period,project
from verify_owner_reading import reading_position
from verify_readtime_upload import counters
from verify_web_source_progress import BASE as WEB


class Preflight(NativeProbe):
    def __init__(self,source=None,store=None,opener=None,clock=time.time,sleep=time.sleep):
        super().__init__(opener);self.source=source or SelectionProbe();self.store=store or CaptureStore()
        self.clock,self.sleep=clock,sleep;self.identity=self.grant=self.statistics_url=None;self.gets=0

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if (self.identity is None or body is not None or credentials is None or digest(credentials)!=self.grant
                or url not in (BASE+'/book/info?bookId='+self.identity,BASE+'/book/getProgress?bookId='+self.identity,self.statistics_url)
                or self.gets>=6):raise ValueError('cross_day/read_scope')
        self.gets+=1;return super().request(stage,url,credentials=credentials,timeout=timeout)

    def run(self,saved,credentials,on_final=None):
        state,receipt=self.store.read()
        if self.identity is not None or state is None:raise ValueError('cross_day/capture_missing_or_reused')
        p=validate(state['plan'])
        if self.clock()<p['not_before']:raise ValueError('cross_day/not_ready')
        if saved['vid']!=credentials['vid'] or saved['vid']!=p['source']['owner']:raise ValueError('cross_day/owner')
        if digest(credentials['deviceId'])!=p['device_sha256']:raise ValueError('cross_day/device')
        self.grant=digest(credentials);self.identity=p['source']['book_id']
        self.statistics_url=BASE+'/readdata/detail?mode=monthly&baseTime='+str(period('monthly',p['start_time'])[0])
        source=self.source.prepare(saved,credentials,existing=p['source'])
        if source.bound!=p['source'] or source.context['bookVersion']!=p['book_version']:raise ValueError('cross_day/source')
        catalog,chapters=normalize_chapter_infos(self.source.web.request('catalog_after',WEB+'/web/book/chapterInfos',dict(bookIds=[self.identity])),self.identity)
        book=catalog.get('book',{});version=book.get('bookVersion',book.get('version')) if isinstance(book,dict) else None
        if not integer(version,1,2147483647) or version!=p['book_version'] or chapters!=source.chapters:raise ValueError('cross_day/catalog')
        observations=[]
        for index in range(2):
            if index:self.sleep(2)
            if self.clock()<p['not_before']:raise ValueError('cross_day/clock')
            self.source.baseline(credentials,'cross_day_originals_'+str(index))
            meta=self.request('cross_day_version_'+str(index),BASE+'/book/info?bookId='+self.identity,credentials=credentials)
            version=meta.get('bookVersion',meta.get('version'))
            if str(meta.get('bookId'))!=self.identity or not integer(version,1,2147483647) or version!=p['book_version']:raise ValueError('cross_day/version')
            raw=self.request('cross_day_counter_'+str(index),BASE+'/book/getProgress?bookId='+self.identity,credentials=credentials)
            stamp=raw.get('timestamp')
            if not integer(stamp,1,4102444800) or abs(stamp-self.clock())>60 or stamp<p['not_before']:raise ValueError('cross_day/server_clock')
            if point(raw,self.identity)!=source.baseline['position']:raise ValueError('cross_day/position')
            count=counters(raw,self.identity)
            if digest(count)!=p['counters_sha256']:raise ValueError('cross_day/counters')
            stat=project(self.request('cross_day_statistics_'+str(index),self.statistics_url,credentials=credentials),'monthly',p['start_time'])
            projection={k:stat[k] for k in ('baseTime','readTimes','totalReadTime','readDays')}
            observations.append((count,projection))
        if observations[0]!=observations[1]:raise ValueError('cross_day/statistics_changed')
        self.source.baseline(credentials,'cross_day_final_originals');self.source.web.verify_account()
        if reading_position(self.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+self.identity),self.identity)!=source.web_position:
            raise ValueError('cross_day/web_position')
        if on_final:on_final()
        self.source.current()
        if self.store.read()!=(state,receipt):raise ValueError('cross_day/capture_replaced')
        return dict(result='PASS_CROSS_DAY_READONLY',account_data_posts=0,authentication_posts=0,independent_reads=2,
            captured_device_source_version_counters_exact=True,original_positions_and_records_exact=True,
            historical_month_statistics_stable=True,capture_unchanged=True,future_write_granted=False,
            historical_accounting_verified=False)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    result=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,future_write_granted=False,historical_accounting_verified=False)
    probe=saved=credentials=None
    try:
        if args.saved_session:
            session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid']);probe=Preflight()
            result=probe.run(saved,credentials,on_final=lambda:prepare_web_handoff(session,saved,probe.source))
    except (Exception,KeyboardInterrupt) as error:
        result.update(result='UNVERIFIED')
        if isinstance(error,ValueError) and re.fullmatch(r'(?:cross_day|selection_trial)/[a-z_]{1,64}',str(error)):result['reason']=str(error)
    finally:
        if probe:
            result['stages']={name:[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in transport.report['stages']]
                for name,transport in (('native',probe),('source_native',probe.source.notes),('source_web',probe.source.web))}
            probe.source.web.shards.clear();probe.source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(result,indent=2));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
