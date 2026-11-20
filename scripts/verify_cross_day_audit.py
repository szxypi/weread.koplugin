#!/usr/bin/env python3
"""Read-only zero-removal audit of an ACKed, consumed historical experiment.

Default is offline. --saved-session only reads; --close-unverified additionally
archives that exact local record with an audit. No upload, renewal, replay,
capture changes, original-plan edits or conversion of the old trial to success.
"""
import argparse,json,re,subprocess,time
from annotation_experiment_model import digest
from cross_day_trial import TrialStore,expected_months
from fetch_weread_epub import normalize_chapter_infos
from readtime_history_capture import CaptureStore
from readtime_statistics import reconstruct
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


def lua_compare(command,expected,observed):
    child=subprocess.run(command,input=json.dumps(dict(options=expected,observed=observed)).encode(),capture_output=True,timeout=45)
    frame=b'\nWEREAD_READTIME_STATISTICS='
    if child.returncode or len(child.stdout)>32768 or child.stdout.count(frame)!=1:raise ValueError('cross_audit/lua_frame')
    value=json.loads(child.stdout.split(frame)[1])
    if (not isinstance(value,dict) or set(value)!={'matching_candidates','removed_zero_buckets','read_days_delta'}
            or value['matching_candidates']!=1 or type(value['matching_candidates']) is not int
            or not integer(value['removed_zero_buckets'],0,2) or not integer(value['read_days_delta'],0,1)):
        raise ValueError('cross_audit/lua_schema')
    return {k:value[k] for k in ('removed_zero_buckets','read_days_delta')}


class Audit(NativeProbe):
    def __init__(self,source=None,store=None,capture=None,opener=None,clock=time.time,sleep=time.sleep):
        super().__init__(opener);self.source=source or SelectionProbe();self.store=store or TrialStore();self.capture=capture or CaptureStore()
        self.clock,self.sleep=clock,sleep;self.identity=self.grant=None;self.months={};self.gets=0

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if (self.identity is None or body is not None or credentials is None or digest(credentials)!=self.grant or self.gets>=8
                or url not in {BASE+'/book/info?bookId='+self.identity,BASE+'/book/getProgress?bookId='+self.identity,*self.months.values()}):
            raise ValueError('cross_audit/read_scope')
        self.gets+=1;return super().request(stage,url,credentials=credentials,timeout=timeout)

    def run(self,saved,credentials,*,close=False,lua_command=None,on_final=None):
        if type(close) is not bool or self.identity is not None:raise ValueError('cross_audit/mode')
        state,receipt=self.store.read()
        if state is None or state['phase']!='acknowledged' or state['posts']!=1:raise ValueError('cross_audit/scope')
        plan=state['plan'];cap=plan['capture'];captured=self.capture.read()
        if (captured[0] is None or captured[0]['plan']!=cap or digest(captured[0])!=plan['capture_record_sha256']):
            raise ValueError('cross_audit/capture')
        if saved['vid']!=credentials['vid'] or credentials['vid']!=cap['source']['owner'] or digest(credentials['deviceId'])!=cap['device_sha256']:
            raise ValueError('cross_audit/owner_device')
        self.identity=cap['source']['book_id'];self.grant=digest(credentials)
        self.months={str(period('monthly',stamp)[0]):BASE+'/readdata/detail?mode=monthly&baseTime='+str(period('monthly',stamp)[0])
            for stamp in (cap['start_time'],plan['created_at'])}
        p=self.source.prepare(saved,credentials,existing=cap['source'])
        if p.bound!=cap['source'] or p.context['bookVersion']!=cap['book_version']:raise ValueError('cross_audit/source')
        observations=[];checks=[]
        for index in range(2):
            if index:self.sleep(2)
            self.source.baseline(credentials,'cross_audit_originals_'+str(index))
            raw=self.request('cross_audit_count_'+str(index),BASE+'/book/getProgress?bookId='+self.identity,credentials=credentials)
            if not integer(raw.get('timestamp'),1,4102444800) or abs(raw['timestamp']-self.clock())>60:raise ValueError('cross_audit/clock')
            if point(raw,self.identity)!=p.baseline['position']:raise ValueError('cross_audit/position')
            count=counters(raw,self.identity)
            if count['readingTime']<2 or digest(dict(count,readingTime=count['readingTime']-2))!=cap['counters_sha256']:
                raise ValueError('cross_audit/counters')
            stats={}
            for key,url in self.months.items():
                value=project(self.request('cross_audit_statistics_'+str(index),url,credentials=credentials),'monthly',int(key))
                stats[key]={k:value[k] for k in ('baseTime','readTimes','totalReadTime','readDays')}
            rebuilt=reconstruct(plan,stats)
            if rebuilt is None:raise ValueError('cross_audit/baseline_digest')
            before,check=rebuilt
            if lua_command:
                actual=lua_compare(lua_command,expected_months(before,cap,plan['created_at']),stats)
                if actual!={k:check[k] for k in ('removed_zero_buckets','read_days_delta')}:raise ValueError('cross_audit/lua_mismatch')
            observations.append(dict(counters=count,statistics=stats));checks.append(check)
        if observations[0]!=observations[1] or checks[0]!=checks[1]:raise ValueError('cross_audit/changed')
        self.source.baseline(credentials,'cross_audit_final_originals')
        metadata=self.request('cross_audit_version',BASE+'/book/info?bookId='+self.identity,credentials=credentials)
        version=metadata.get('bookVersion',metadata.get('version'))
        if str(metadata.get('bookId'))!=self.identity or not integer(version,1,2147483647) or version!=cap['book_version']:
            raise ValueError('cross_audit/version')
        catalog,chapters=normalize_chapter_infos(self.source.web.request('catalog_after',WEB+'/web/book/chapterInfos',dict(bookIds=[self.identity])),self.identity)
        book=catalog.get('book',{});version=book.get('bookVersion',book.get('version')) if isinstance(book,dict) else None
        if not integer(version,1,2147483647) or version!=cap['book_version'] or chapters!=p.chapters:raise ValueError('cross_audit/catalog')
        self.source.web.verify_account()
        if reading_position(self.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+self.identity),self.identity)!=p.web_position:
            raise ValueError('cross_audit/web_position')
        if on_final:on_final()
        self.source.current()
        if self.store.read()!=(state,receipt) or self.capture.read()!=captured:raise ValueError('cross_audit/replaced')
        audit=dict(protocol='cross-day-zero-removal-readonly-audit-v1',plan_sha256=digest(plan),prior_record_sha256=digest(state),
            observations_sha256=digest(observations),checked_at=int(self.clock()),independent_reads=2,was_acknowledged=True,
            original_trial_unverified=True,replay_forbidden=True,baseline_digest_exact=True,capture_unchanged=True,
            source_positions_catalog_versions_exact=True,book_counter_delta=2,historical_day_delta=2,dispatch_day_delta=0,
            removed_zero_buckets=checks[0]['removed_zero_buckets'],read_days_delta=checks[0]['read_days_delta'])
        if close:
            final=self.store.close_unverified(receipt,audit);after,r=self.store.read()
            if r!=final or after['plan']!=plan or after['posts']!=1 or after['phase']!='closed_unverified' or after['closure']!=audit:
                raise ValueError('cross_audit/closure_readback')
        return dict(result='UNVERIFIED_TRIAL_CLOSED' if close else 'PASS_READONLY_ZERO_REMOVAL_AUDIT',account_data_posts=0,authentication_posts=0,
            original_trial_verified=False,historical_duration_attribution_verified=True,independent_reads=2,baseline_digest_exact=True,
            book_counter_delta=2,historical_day_delta=2,dispatch_day_delta=0,removed_zero_buckets=audit['removed_zero_buckets'],
            read_days_delta=audit['read_days_delta'],python_lua_agree=bool(lua_command),original_source_positions_catalog_versions_exact=True,
            capture_unchanged=True,scope_retained=True,scope_reusable=False,explicit_receipt_retained=True)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--close-unverified',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,original_trial_verified=False)
    probe=saved=grant=None
    try:
        if (args.close_unverified or args.lua_command is not None) and not args.saved_session:raise ValueError('cross_audit/offline')
        if args.lua_command is not None and not args.lua_command:raise ValueError('cross_audit/lua_command')
        if args.saved_session:
            session=SessionStore();saved=session.load();grant=NativeSessionStore().load(saved['vid']);probe=Audit()
            report=probe.run(saved,grant,close=args.close_unverified,lua_command=args.lua_command,
                on_final=lambda:prepare_web_handoff(session,saved,probe.source))
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED')
        if isinstance(error,ValueError) and re.fullmatch(r'(?:cross_audit|time_statistics|cross_trial|selection_trial)/[a-z_]{1,64}',str(error)):
            report['reason']=str(error)
    finally:
        if probe:
            report['stages']={name:[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in api.report['stages']]
                for name,api in (('native',probe),('source_native',probe.source.notes),('source_web',probe.source.web))}
            probe.source.web.shards.clear();probe.source.web.close()
        for value in (saved,grant):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
