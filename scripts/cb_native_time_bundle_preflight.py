"""Scoped, read-only CB cross-day preflight. No dispatch or renewal path."""
from copy import deepcopy
from dataclasses import dataclass
import time
from urllib.parse import urlencode

from annotation_experiment_model import digest
from cb_native_time_bundle_evidence import PreflightEvidence
from cb_native_time_bundle_gate import binding,day
from readtime_upload_model import integer
from secure_weread_session import MacKeychain
from verify_cb_native_time_capture import CaptureWeb,snapshot
from verify_eink_login import BASE,NativeProbe
from verify_native_statistics import period,project
from verify_translation_preflight import save_refreshed_web_session


@dataclass(repr=False)
class Prepared:
    bundle:dict
    receipt:object
    grant:dict
    evidence:PreflightEvidence
    def __repr__(self):return '<CBPreparedPreflight private>'
    def close(self):
        self.bundle.clear();self.grant.clear();self.receipt=None;self.evidence=None


class ReadOnlyNative(NativeProbe):
    def __init__(self,grant,book,months,not_before,current,clock=time.time,opener=None):
        super().__init__(opener);self.grant=deepcopy(grant);self.book=book;self.months=set(months)
        self.not_before,self.current,self.clock=not_before,current,clock;self.used={};self.server_times=[]
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        identity=urlencode({'bookId':self.book})
        fixed={('cb_capture_progress',BASE+'/book/getProgress?'+identity),('cb_capture_info',BASE+'/book/info?'+identity),
               ('cb_capture_shelf',BASE+'/shelf/sync')}
        stats={('cb_preflight_stats',BASE+'/readdata/detail?mode=monthly&baseTime='+str(month)) for month in self.months}
        key=(stage,url)
        if (key not in fixed|stats or body is not None or credentials!=self.grant or self.used.get(key,0)>=2
                or self.current() is not True):raise ValueError('cb_preflight/native_scope')
        self.used[key]=self.used.get(key,0)+1
        value=super().request(stage,url,credentials=credentials,timeout=timeout)
        if self.current() is not True:raise ValueError('cb_preflight/session')
        if stage=='cb_capture_progress':
            stamp=value.get('timestamp') if isinstance(value,dict) else None;now=int(self.clock())
            if not integer(stamp,self.not_before,4102444800) or abs(stamp-now)>60:raise ValueError('cb_preflight/server_clock')
            self.server_times.append(stamp)
        return value
    def close(self):self.grant.clear()


class GuardedWeb(CaptureWeb):
    def __init__(self,current):super().__init__();self.current=current
    def request(self,stage,url,body=None,**options):
        if self.current() is not True:raise ValueError('cb_preflight/session')
        value=super().request(stage,url,body,**options)
        if self.current() is not True:raise ValueError('cb_preflight/session')
        return value


def run(store,session,native_store,gate,audit_store,*,clock=time.time,sleep=time.sleep,
        web_factory=GuardedWeb,native_factory=ReadOnlyNative):
    report=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,private_data_in_report=False)
    packet=saved=grant=native=None;webs=[];phase='capture'
    try:
        real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (store,gate,audit_store))
        if real and (clock is not time.time or sleep is not time.sleep or web_factory is not GuardedWeb or native_factory is not ReadOnlyNative):
            raise ValueError('cb_preflight/override')
        bundle,receipt=store.read()
        if not bundle or not receipt:raise ValueError('cb_preflight/missing')
        plan=bundle['plan'];started=int(clock())
        if started<plan['not_before'] or day(started)<=day(plan['start_time']):
            report['result']='NOT_YET_HISTORICAL';return report,None
        if gate.read()!=(None,None) or audit_store.read()!=(None,None):raise ValueError('cb_preflight/pending')
        phase='session';saved=session.load();grant=native_store.load(saved['vid'])
        if saved['vid']!=plan['owner']:raise ValueError('cb_preflight/owner')
        bundle_hash,grant_hash=digest(bundle),digest(grant)
        def access_current():
            return session.load()==saved and digest(native_store.load(saved['vid']))==grant_hash
        def scope_current():
            current,token=store.read()
            return (token==receipt and current is not None and digest(current)==bundle_hash and access_current()
                    and gate.read()==(None,None) and audit_store.read()==(None,None))
        if not scope_current():raise ValueError('cb_preflight/session')
        months={period('monthly',plan['start_time'])[0],period('monthly',started)[0]}
        native=native_factory(grant,plan['book_id'],months,plan['not_before'],access_current,clock)
        observations=[];statistics=[];pairs=[];phase='source'
        for index in range(2):
            if index:sleep(2)
            if not scope_current():raise ValueError('cb_preflight/session')
            phase='web'
            web=web_factory(access_current);webs.append(web);web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();web.allowed={plan['book_id']};web.request('shelf','https://weread.qq.com/web/shelf/sync')
            sample=web.inspect(plan['book_id']);web.verify_account()
            phase='snapshot';observed=snapshot(web,sample,native,grant)
            if sample['chapter_uid']!=plan['chapter_uid'] or observed['native']['chapter_idx']!=plan['chapter_idx']:
                raise ValueError('cb_preflight/source')
            phase='binding';binding(bundle,grant,observed,int(clock()))
            observations.append(observed);pairs.append(deepcopy(web.catalogs))
            values={};phase='statistics'
            for month in months:
                raw=native.request('cb_preflight_stats',BASE+'/readdata/detail?mode=monthly&baseTime='+str(month),credentials=grant)
                value=project(raw,'monthly',month,int(clock()))
                values[str(month)]={key:value[key] for key in ('baseTime','readTimes','totalReadTime','readDays')}
            statistics.append(values)
            if save_refreshed_web_session(session,saved,web):
                fresh=session.load()
                if fresh['vid']!=saved['vid']:raise ValueError('cb_preflight/owner')
                saved.clear();saved=fresh
            phase='source'
        completed=int(clock())
        phase='evidence'
        if (len(native.server_times)!=2 or digest(observations[0])!=digest(observations[1])
                or digest(statistics[0])!=digest(statistics[1]) or not 0<=completed-started<=90
                or day(completed)!=day(started) or not scope_current()):raise ValueError('cb_preflight/changed')
        report=dict(result='CB_CROSS_DAY_READONLY_VERIFIED',seconds=plan['seconds'],observed_months=len(months),completed_at=completed,
                    exact_capture_and_source_bound=True,both_positions_counts_source_shelves_exact=True,two_statistics_reads_stable=True,
                    server_clock_after_boundary=True,account_data_posts=0,authentication_posts=0,historical_accounting_verified=False,
                    dispatch_capability=False)
        evidence=PreflightEvidence(bundle,grant,report,observations[1],statistics[1],pairs)
        if not scope_current():raise ValueError('cb_preflight/session')
        packet=Prepared(deepcopy(bundle),receipt,deepcopy(grant),evidence)
    except Exception as error:
        report=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,private_data_in_report=False,
                    failure_stage=phase,failure_type=type(error).__name__ if type(error).__name__ in ('ValueError','TypeError','KeyError') else 'other')
        allowed={'cb_bundle/bundle','cb_bundle/owner','cb_bundle/not_historical','cb_bundle/baseline','cb_bundle/counts',
                 'cb_bundle/position','cb_bundle/summary','cb_preflight/native_scope','cb_preflight/session','cb_preflight/server_clock',
                 'cb_preflight/source','cb_preflight/changed','cb_preflight/pending','cb_preflight/override','cb_preflight/owner'}
        if isinstance(error,ValueError) and str(error) in allowed:report['failure_reason']=str(error)
    finally:
        latest=next((web for web in reversed(webs) if getattr(web,'authenticated',False)),None)
        if latest and saved:
            try:save_refreshed_web_session(session,saved,latest)
            except Exception:
                report=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,private_data_in_report=False)
                if packet:packet.close();packet=None
        for web in webs:
            web.samples.clear();web.progress.clear();web.catalogs.clear();web.close()
        if native:native.close()
        for item in (saved,grant):
            if isinstance(item,dict):item.clear()
    return report,packet
