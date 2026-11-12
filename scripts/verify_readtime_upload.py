#!/usr/bin/env python3
"""One two-second current-source protocol experiment; offline by default.

No historical ledger is claimed or uploaded. --saved-session alone is read-only;
--apply uses the owner's continuing development grant. One durable claim, one
POST, no renewal, retries or fallback. Unknown outcomes remain in Keychain.
"""
import argparse
from copy import deepcopy
import json,math,re,secrets,time
from urllib.parse import parse_qs,urlsplit
from annotation_experiment_model import digest
from fetch_weread_epub import normalize_chapter_infos
from readtime_trial_model import bind
from readtime_upload_model import batch,confirmed,guest_token,integer,local_zone
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_readtime_trial import ReadtimeTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from selection_trial_probe import SelectionProbe,prepare_web_handoff
from verify_eink_login import BASE,NativeProbe,ProbeError
from verify_eink_readtime import validate_position
from verify_native_statistics import project,period
from verify_native_thought_trial import other_pending
from verify_owner_reading import reading_position
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


def counters(value,identity):
    validate_position(value,identity)
    node=value
    for _i in range(4):
        if isinstance(node,dict) and 'chapterUid' in node:break
        if not isinstance(node,dict):raise ValueError('readtime/counters')
        node=node.get('book',node.get('data',node.get('result')))
    if not isinstance(node,dict) or any(not integer(node.get(k),0,2**53-1) for k in ('readingTime','recordReadingTime','ttsTime')):raise ValueError('readtime/counters')
    return {k:node[k] for k in ('readingTime','recordReadingTime','ttsTime')}


def statistics(value,now):
    p=project(value,'monthly',0,now)
    return {k:p[k] for k in ('baseTime','readTimes','totalReadTime','readDays')}


def expected_statistics(before,start,duration,*,time_zone='+08:00'):
    from readtime_upload_model import zone
    tz=zone(time_zone);offset=(int(tz[1:3])*60+int(tz[4:]))*60*(1 if tz[0]=='+' else -1)
    # Statistics keys label calendar dates at CST midnight; reported Hour zones
    # may select the captured local date instead of the server's current date.
    day=(start+offset)//86400*86400-28800
    if day!=(start+duration-1+offset)//86400*86400-28800:raise ValueError('readtime/day_boundary')
    value=deepcopy(before);key=str(day);previous=value['readTimes'].get(key,0)
    value['readTimes'][key]=previous+duration;value['totalReadTime']+=duration
    if previous==0:value['readDays']+=1
    return value


class ReadingTimeTrial(NativeProbe):
    def __init__(self,source=None,store=None,opener=None,clock=time.time,sleep=time.sleep,monotonic=time.monotonic):
        super().__init__(opener);self.source=source or SelectionProbe();self.store=store or ReadtimeTrialStore()
        self.clock=clock;self.sleep=sleep;self.monotonic=monotonic
        self.identity=self.credentials_hash=self.before=self.stats=self.rows=self.body=self.bound=self.receipt=None
        self.gets=self.posts=0;self.success_receipt=False;self.report.update(account_data_posts=0,authentication_posts=0)

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        parsed=urlsplit(url);query=parse_qs(parsed.query,keep_blank_values=True)
        if parsed.scheme!='https' or parsed.netloc!='i.weread.qq.com' or parsed.fragment or credentials is None or digest(credentials)!=self.credentials_hash:raise ValueError('readtime/scope')
        if body is None:
            allowed=(parsed.path=='/config' and query=={'token':['1']} or parsed.path=='/feature' and query=={'synckey':['0']}
                or parsed.path in ('/book/getProgress','/book/info') and self.identity is not None and query=={'bookId':[self.identity]}
                or parsed.path=='/readdata/detail' and query=={'mode':['monthly'],'baseTime':['0']})
            if not allowed or self.gets>=48:raise ValueError('readtime/read_scope')
            self.gets+=1
        else:
            self.current(credentials);state,receipt=self.store.read()
            if (stage!='readtime_dispatch' or parsed.path!='/book/batchUploadProgress' or parsed.query or self.posts!=0
                    or body!=self.body or digest(body)!=self.bound['request_sha256'] or receipt!=self.receipt
                    or state is None or state['phase']!='claimed' or state['plan']!=self.bound):raise ValueError('readtime/write_scope')
            self.posts=1;self.report['account_data_posts']=1
        return super().request(stage,url,body,credentials,timeout)

    def current(self,credentials):
        self.source.current()
        if self.body is not None and not 0<=self.clock()-self.body['books'][0]['timestamp']<30:raise ValueError('readtime/stale_request')
        if (self.bound is None or self.bound!=bind(self.source.plan.bound,self.body,credentials,self.before,self.rows,self.stats)
                or digest(credentials)!=self.credentials_hash):raise ValueError('readtime/changed')

    def read_counters(self,credentials,stage):
        raw=self.request(stage,BASE+'/book/getProgress?bookId='+self.identity,credentials=credentials)
        if not integer(raw.get('timestamp'),1,4102444800) or abs(raw['timestamp']-self.clock())>60:raise ValueError('readtime/server_clock')
        from verify_finish_roundtrip import point
        if point(raw,self.identity)!=self.source.plan.baseline['position']:raise ValueError('readtime/position_changed')
        return counters(raw,self.identity)

    def read_statistics(self,credentials,stage):
        return statistics(self.request(stage,BASE+'/readdata/detail?mode=monthly&baseTime=0',credentials=credentials),int(self.clock()))

    def prepare(self,saved,credentials):
        if self.bound is not None or self.store.read()!=(None,None):raise ValueError('readtime/pending')
        self.credentials_hash=digest(credentials);p=self.source.prepare(saved,credentials);self.identity=p.bound['book_id']
        config=self.request('readtime_config',BASE+'/config?token=1',credentials=credentials)
        feature=self.request('readtime_feature',BASE+'/feature?synckey=0',credentials=credentials);guest,kind=guest_token(feature)
        metadata=self.request('readtime_metadata',BASE+'/book/info?bookId='+self.identity,credentials=credentials)
        version=metadata.get('bookVersion',metadata.get('version'))
        catalog,chapters=normalize_chapter_infos(self.source.web.request('catalog_after',WEB+'/web/book/chapterInfos',dict(bookIds=[self.identity])),self.identity)
        web_book=catalog.get('book',{});web_version=web_book.get('bookVersion',web_book.get('version')) if isinstance(web_book,dict) else None
        if str(metadata.get('bookId'))!=self.identity or not integer(version,1,2147483647) or not integer(web_version,1,2147483647) or web_version!=version or p.context['bookVersion']!=version or chapters!=p.chapters:raise ValueError('readtime/version_unverified')
        self.before=self.read_counters(credentials,'readtime_counter_before');self.stats=self.read_statistics(credentials,'readtime_statistics_before')
        self.source.baseline(credentials,'readtime_before_window')
        # Explicit synthetic validation interval, not a claimed user ledger row.
        wall=self.clock();mono=self.monotonic();start=math.ceil(wall);self.sleep(max(0,start+2-wall)+.01)
        now=self.clock()
        if now<start+2 or now-wall>4 or not 2<=self.monotonic()-mono<=4:raise ValueError('readtime/capture_clock')
        self.rows=[dict(start_time=start,duration=2,time_zone=local_zone(),book_version=version)]
        calendars={'server_calendar_day':expected_statistics(self.stats,start,2),'captured_calendar_day':expected_statistics(self.stats,start,2,time_zone=self.rows[0]['time_zone'])}
        # readDays is an independently returned statistic; its qualification
        # threshold is not documented. One controlled day can qualify zero or
        # one day. Exact duration and every other daily bucket remain fixed.
        self.stats_candidates={name+':days_'+str(delta):dict(value,readDays=self.stats['readDays']+delta)
            for name,value in calendars.items() for delta in (0,1)}
        first,last=period('monthly',int(self.clock()))
        if self.stats['baseTime']!=first or any(not first<=int(k)<last for v in self.stats_candidates.values() for k in v['readTimes']):raise ValueError('readtime/month_boundary')
        if self.read_counters(credentials,'readtime_counter_stable')!=self.before or self.read_statistics(credentials,'readtime_statistics_stable')!=self.stats:raise ValueError('readtime/concurrent_before')
        self.source.baseline(credentials,'readtime_after_window')
        stamp=int(self.clock()*1000);now=stamp//1000
        self.body=batch(credentials,self.identity,self.rows,guest,config.get('token'),now,secrets.randbelow(1000),stamp,secrets.randbelow(1000),current_zone=local_zone())
        self.protocol_input=dict(credentials=deepcopy(credentials),book_id=self.identity,rows=deepcopy(self.rows),guest_token=guest,config_token=config['token'],
            now=now,random=self.body['books'][0]['random'],envelope=dict(timestamp=stamp,random=self.body['random'],current_zone=local_zone()))
        self.bound=bind(p.bound,self.body,credentials,self.before,self.rows,self.stats)
        self.report.update(current_catalog_version_matched=True,signature_token_source=kind,controlled_test_seconds=2,historical_ledger_rows=0,
            source_snapshot_verified=True,server_clock_verified=True,captured_time_zone=self.rows[0]['time_zone'],original_records_unchanged=True)
        return self.bound

    def run(self,credentials,*,apply=False,on_final=None):
        if type(apply) is not bool:raise ValueError('readtime/mode')
        self.current(credentials)
        if self.store.read()!=(None,None):raise ValueError('readtime/pending')
        self.source.baseline(credentials,'readtime_before_dispatch')
        if self.read_counters(credentials,'readtime_counter_final_preflight')!=self.before or self.read_statistics(credentials,'readtime_stats_final_preflight')!=self.stats:raise ValueError('readtime/concurrent_before')
        if apply:
            self.receipt=self.store.reserve(self.bound);self.receipt=self.store.advance(self.receipt,'claimed')
            try:self.success_receipt=confirmed(self.request('readtime_dispatch',BASE+'/book/batchUploadProgress',body=self.body,credentials=credentials,timeout=20))
            except ProbeError:pass
            expected=dict(self.before,readingTime=self.before['readingTime']+2);matched=False
            for attempt in range(4):
                if attempt:self.sleep(min(5,attempt*2))
                self.source.baseline(credentials,'readtime_readback_records')
                count=self.read_counters(credentials,'readtime_readback_counter');stat=self.read_statistics(credentials,'readtime_readback_statistics')
                if count not in (self.before,expected) or stat not in (self.stats,*self.stats_candidates.values()):
                    self.report['observed_counter_delta']={k:count[k]-self.before[k] for k in count}
                    self.report['observed_monthly_delta']=stat['totalReadTime']-self.stats['totalReadTime']
                    self.report['observed_read_days_delta']=stat['readDays']-self.stats['readDays']
                    self.report['observed_daily_deltas']=sorted(v-self.stats['readTimes'].get(k,0) for k,v in stat['readTimes'].items() if v!=self.stats['readTimes'].get(k,0))
                    raise ValueError('readtime/unrelated_delta')
                matches=[k for k,v in self.stats_candidates.items() if stat==v]
                if count==expected and matches:
                    calendars={name.split(':')[0] for name in matches}
                    self.report['statistics_calendar_attribution']=next(iter(calendars)) if len(calendars)==1 else 'same_calendar_date'
                    self.report['read_days_delta_observed']=stat['readDays']-self.stats['readDays']
                    matched=True;break
            if not self.success_receipt or not matched:raise ValueError('readtime/not_confirmed')
        self.source.baseline(credentials,'readtime_final_records');self.source.web.verify_account()
        after=reading_position(self.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+self.identity),self.identity)
        if after!=self.source.plan.web_position:raise ValueError('readtime/web_position')
        if on_final:on_final()
        if apply:
            self.receipt=self.store.advance(self.receipt,'verified');self.store.finish(self.receipt)
        self.report.update(result='PASS_PROTOCOL' if apply else 'PASS_READONLY',account_data_posts=self.posts,explicit_success_receipt=self.success_receipt,
            book_counter_delta=2 if apply else 0,monthly_total_delta=2 if apply else 0,daily_bucket_delta=2 if apply else 0,
            original_records_unchanged=True,web_and_native_positions_unchanged=True,intent_state='absent',no_automatic_replay=True,
            pending=['historical_file_bound_ledger','web_offline_dispatch_coordination','native_upload_ui_and_queue','cross_month_zone_attribution'])
        return self.report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');m=parser.add_mutually_exclusive_group()
    m.add_argument('--apply',action='store_true');m.add_argument('--status',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=ReadtimeTrialStore()
            if args.status:
                state,_r=store.read();legacy,_r=ReadtimeTrialStore(version=1).read()
                report.update(result='PASS',intent_state=state['phase'] if state else 'absent',legacy_intent_state=legacy['phase'] if legacy else 'absent')
            else:
                if other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('readtime/other_pending')
                phase='load';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=ReadingTimeTrial(store=store);phase='prepare';probe.prepare(saved,credentials)
                phase='handoff';saved=prepare_web_handoff(session,saved,probe.source)
                phase='apply' if args.apply else 'read_only'
                report=probe.run(credentials,apply=args.apply,on_final=lambda:save_refreshed_web_session(session,saved,probe.source.web))
        elif args.apply or args.status:raise ValueError('readtime/offline')
    except (Exception,KeyboardInterrupt) as error:
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=probe.posts if probe else 0,authentication_posts=0,no_automatic_replay=True)
        if isinstance(error,ValueError) and re.fullmatch(r'readtime/[a-z_]{1,64}',str(error)):report['reason']=str(error)
        if probe:report['explicit_success_receipt']=probe.success_receipt
    finally:
        if probe:
            report.update({k:v for k,v in probe.report.items() if k not in ('stages','result')})
            report['stages']={name:[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in transport.report['stages']] for name,transport in [('native',probe),('source_native',probe.source.notes),('source_web',probe.source.web)]}
            state,_r=probe.store.read();report['intent_state']=state['phase'] if state else 'absent'
            probe.source.web.shards.clear();probe.source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
