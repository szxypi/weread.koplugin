#!/usr/bin/env python3
"""Read-only diagnosis of a consumed v2 request. Never sends or renews.

Default is offline. --saved-session reads the exact source and both counters
twice. --retire-unverified archives the unchanged claim in Keychain, without
marking success, deleting the record, or making its old scope reusable.
"""
import argparse
import json,re,time
from annotation_experiment_model import digest
from secure_readtime_trial import ReadtimeTrialStore
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from selection_trial_probe import SelectionProbe
from selection_trial_probe import prepare_web_handoff
from verify_eink_login import NativeProbe,BASE
from verify_finish_roundtrip import point
from verify_owner_reading import reading_position
from verify_web_source_progress import BASE as WEB
from verify_readtime_upload import counters,statistics
from verify_native_statistics import period


class Recovery(NativeProbe):
    def __init__(self,source=None,store=None,opener=None,clock=time.time,sleep=time.sleep):
        super().__init__(opener);self.source=source or SelectionProbe();self.store=store or ReadtimeTrialStore()
        self.clock,self.sleep=clock,sleep;self.gets=0;self.identity=self.grant=self.statistics_url=None

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if (body is not None or self.identity is None or credentials is None or digest(credentials)!=self.grant
                or url not in (BASE+'/book/getProgress?bookId='+self.identity,self.statistics_url) or self.gets>=4):
            raise ValueError('readtime_recovery/read_scope')
        self.gets+=1;return super().request(stage,url,credentials=credentials,timeout=timeout)

    def run(self,saved,credentials,*,retire=False,on_final=None):
        if type(retire) is not bool:raise ValueError('readtime_recovery/mode')
        state,receipt=self.store.read()
        if not state or state['phase']!='claimed' or self.identity is not None:raise ValueError('readtime_recovery/scope')
        plan=state['plan'];self.identity=plan['source']['book_id'];self.grant=digest(credentials)
        if credentials['vid']!=plan['source']['owner'] or saved['vid']!=credentials['vid']:raise ValueError('readtime_recovery/owner')
        self.statistics_url=BASE+'/readdata/detail?mode=monthly&baseTime='+str(period('monthly',plan['start_time'])[0])
        self.source.prepare(saved,credentials,existing=plan['source']);observed=[]
        for index in range(2):
            if index:self.sleep(2)
            self.source.baseline(credentials,'readtime_recovery_originals_'+str(index))
            raw=self.request('readtime_recovery_counter_'+str(index),BASE+'/book/getProgress?bookId='+self.identity,credentials=credentials)
            if type(raw.get('timestamp')) is not int or abs(raw['timestamp']-self.clock())>60:raise ValueError('readtime_recovery/server_clock')
            if point(raw,self.identity)!=self.source.plan.baseline['position']:raise ValueError('readtime_recovery/position')
            count=counters(raw,self.identity)
            stat=statistics(self.request('readtime_recovery_statistics_'+str(index),self.statistics_url,credentials=credentials),int(self.clock()))
            if digest(count)!=plan['counters_sha256'] or digest(stat)!=plan['statistics_sha256']:
                raise ValueError('readtime_recovery/changed')
            observed.append(dict(counters_sha256=digest(count),statistics_sha256=digest(stat)))
        self.source.baseline(credentials,'readtime_recovery_final_originals')
        self.source.web.verify_account()
        if reading_position(self.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+self.identity),self.identity)!=self.source.plan.web_position:
            raise ValueError('readtime_recovery/web_position')
        if on_final:on_final()
        if self.store.read()!=(state,receipt):raise ValueError('readtime_recovery/replaced')
        audit=dict(protocol='unchanged-time-trial-retirement-v1',plan_sha256=digest(plan),observations_sha256=digest(observed),
            checked_at=int(self.clock()),independent_reads=2,original_trial_unverified=True,no_replay=True,
            original_source_and_positions_exact=True,book_counter_unchanged=True,statistics_unchanged=True)
        if retire:
            retired=self.store.retire_unverified(receipt,audit)
            after,r=self.store.read()
            if r!=retired or after['phase']!='retired' or after['plan']!=plan or after['retirement']!=audit:
                raise ValueError('readtime_recovery/readback')
        return dict(result='UNVERIFIED_RETIRED' if retire else 'PASS_READONLY_UNCHANGED',account_data_posts=0,authentication_posts=0,
            independent_reads=2,original_source_and_positions_exact=True,book_counter_unchanged=True,statistics_unchanged=True,
            original_trial_unverified=True,intent_retained=True,no_replay=True,old_scope_reusable=False)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--retire-unverified',action='store_true');args=parser.parse_args(argv)
    result=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=saved=credentials=None
    try:
        if args.saved_session:
            session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid']);probe=Recovery()
            result=probe.run(saved,credentials,retire=args.retire_unverified,on_final=lambda:prepare_web_handoff(session,saved,probe.source))
        elif args.retire_unverified:raise ValueError('readtime_recovery/offline')
    except (Exception,KeyboardInterrupt) as error:
        result.update(result='UNVERIFIED',no_replay=True)
        if isinstance(error,ValueError) and re.fullmatch(r'readtime_recovery/[a-z_]{1,64}',str(error)):result['reason']=str(error)
    finally:
        if probe:
            result['stages']=[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in probe.report['stages']]
            probe.source.web.shards.clear();probe.source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(result,indent=2));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
