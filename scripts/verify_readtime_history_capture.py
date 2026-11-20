#!/usr/bin/env python3
"""Capture one actual two-second test window for later cross-day verification.

No account-data writes, time-upload dispatch, renewal or timestamp edits.
The bounded source proof stays in Keychain. It grants no future network write.
"""
import argparse,json,math,re,time
from annotation_experiment_model import digest
from fetch_weread_epub import normalize_chapter_infos
from readtime_history_capture import CaptureStore,next_cst_day,validate
from readtime_upload_model import integer,local_zone
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from selection_trial_probe import SelectionProbe,prepare_web_handoff
from verify_eink_login import NativeProbe,BASE
from verify_finish_roundtrip import point
from verify_readtime_upload import counters
from verify_owner_reading import reading_position
from verify_web_source_progress import BASE as WEB


class Capture(NativeProbe):
    def __init__(self,source=None,store=None,opener=None,clock=time.time,monotonic=time.monotonic,sleep=time.sleep):
        super().__init__(opener);self.source=source or SelectionProbe();self.store=store or CaptureStore()
        self.clock,self.monotonic,self.sleep=clock,monotonic,sleep;self.identity=self.grant=None;self.gets=0

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if (self.identity is None or body is not None or credentials is None or digest(credentials)!=self.grant
                or url not in (BASE+'/book/info?bookId='+self.identity,BASE+'/book/getProgress?bookId='+self.identity) or self.gets>=6):
            raise ValueError('history_capture/read_scope')
        self.gets+=1;return super().request(stage,url,credentials=credentials,timeout=timeout)

    def counter(self,credentials,stage):
        raw=self.request(stage,BASE+'/book/getProgress?bookId='+self.identity,credentials=credentials)
        if not integer(raw.get('timestamp'),1,4102444800) or abs(raw['timestamp']-self.clock())>60:raise ValueError('history_capture/server_clock')
        if point(raw,self.identity)!=self.source.plan.baseline['position']:raise ValueError('history_capture/position')
        return counters(raw,self.identity)

    def version(self,credentials,stage):
        metadata=self.request(stage,BASE+'/book/info?bookId='+self.identity,credentials=credentials)
        version=metadata.get('bookVersion',metadata.get('version'))
        if str(metadata.get('bookId'))!=self.identity or not integer(version,1,2147483647):raise ValueError('history_capture/version')
        return version

    def run(self,saved,credentials,on_final=None):
        if self.identity is not None or self.store.read()!=(None,None):raise ValueError('history_capture/consumed')
        if saved['vid']!=credentials['vid']:raise ValueError('history_capture/owner')
        self.grant=digest(credentials);p=self.source.prepare(saved,credentials);self.identity=p.bound['book_id']
        version=self.version(credentials,'history_capture_version_before')
        catalog,chapters=normalize_chapter_infos(self.source.web.request('catalog_after',WEB+'/web/book/chapterInfos',dict(bookIds=[self.identity])),self.identity)
        book=catalog.get('book',{});web_version=book.get('bookVersion',book.get('version')) if isinstance(book,dict) else None
        if not integer(web_version,1,2147483647) or web_version!=version or p.context['bookVersion']!=version or chapters!=p.chapters:raise ValueError('history_capture/version')
        before=self.counter(credentials,'history_capture_counter_before');self.source.baseline(credentials,'history_capture_originals_before')
        wall=self.clock();mono=self.monotonic();start=math.ceil(wall)
        self.sleep(max(0,start+2-wall)+.01)
        ended=self.clock();elapsed=self.monotonic()-mono
        if not start+2<=ended<start+4 or not 2<=elapsed<=4 or abs(ended-wall-elapsed)>.25:raise ValueError('history_capture/clock')
        captured=dict(protocol='cross-day-real-window-two-second-v1',source=p.bound,device_sha256=digest(credentials['deviceId']),
            counters_sha256=digest(before),start_time=start,duration=2,time_zone=local_zone(),book_version=version,captured_at=int(ended),
            not_before=next_cst_day(start)+1,monotonic_elapsed_ms=round(elapsed*1000),clock_elapsed_ms=round((ended-wall)*1000))
        validate(captured)
        if self.counter(credentials,'history_capture_counter_after')!=before or self.version(credentials,'history_capture_version_after')!=version:
            raise ValueError('history_capture/changed')
        self.source.baseline(credentials,'history_capture_originals_after')
        self.source.web.verify_account()
        if reading_position(self.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+self.identity),self.identity)!=p.web_position:
            raise ValueError('history_capture/web_position')
        if on_final:on_final()
        receipt=self.store.capture(captured);after,r=self.store.read()
        if r!=receipt or after['plan']!=captured:raise ValueError('history_capture/readback')
        return dict(result='CAPTURED_NO_DISPATCH',account_data_posts=0,authentication_posts=0,controlled_test_seconds=2,
            real_wall_and_monotonic_interval=True,original_source_and_positions_exact=True,counter_unchanged=True,
            future_write_granted=False,source_proof_in_keychain=True,wait_until_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(captured['not_before'])))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--status',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=saved=credentials=None
    try:
        if args.saved_session and args.status:
            value,_r=CaptureStore().read();report.update(result='PASS',capture_present=value is not None,
                ready_for_separate_cross_day_preflight=bool(value and time.time()>=value['plan']['not_before']),future_write_granted=False)
        elif args.saved_session:
            session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid']);probe=Capture()
            report=probe.run(saved,credentials,on_final=lambda:prepare_web_handoff(session,saved,probe.source))
        elif args.status:raise ValueError('history_capture/offline')
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',future_write_granted=False)
        if isinstance(error,ValueError) and re.fullmatch(r'history_capture/[a-z_]{1,64}',str(error)):report['reason']=str(error)
    finally:
        if probe:
            report['stages']=[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in probe.report['stages']]
            probe.source.web.shards.clear();probe.source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
