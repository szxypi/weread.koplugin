"""Read-only, bounded three-sample audit of an acknowledged CB time transfer."""
from copy import deepcopy
import time
from urllib.parse import urlencode

from cb_native_time_bundle_evidence import catalog_check
from cb_native_time_bundle_gate import day
from cb_native_time_bundle_preflight import GuardedWeb
from native_time_bundle_readback import checked_response
from readtime_upload_model import integer
from secure_native_session import NativeSessionStore
from secure_weread_session import MacKeychain,SessionStore
from verify_cb_native_time_capture import snapshot
from verify_eink_login import BASE,NativeProbe
from verify_native_statistics import project
from verify_translation_preflight import save_refreshed_web_session


class NativeReads(NativeProbe):
    """Allow exactly three rounds of the captured book's read-only APIs."""
    def __init__(self,grant,book,months,dispatched,current,clock=time.time,opener=None):
        super().__init__(opener)
        self.grant=deepcopy(grant);self.current=current;self.clock=clock;self.dispatched=dispatched
        identity=urlencode({'bookId':book})
        self.allowed=[('cb_capture_progress',BASE+'/book/getProgress?'+identity),
                      ('cb_capture_info',BASE+'/book/info?'+identity),('cb_capture_shelf',BASE+'/shelf/sync')]
        self.allowed.extend(('cb_readback_stats',BASE+'/readdata/detail?mode=monthly&baseTime='+str(month))
                            for month in sorted(months,key=int))
        if len(self.allowed) not in (4,5):raise ValueError('cb_readback/months')
        self.steps=0;self.server_at=None

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if (self.steps>=3*len(self.allowed) or (stage,url)!=self.allowed[self.steps%len(self.allowed)]
                or body is not None or credentials!=self.grant or self.current() is not True):
            raise ValueError('cb_readback/native_scope')
        self.steps+=1
        value=checked_response(self,super().request(stage,url,credentials=credentials,timeout=timeout))
        if self.current() is not True:raise ValueError('cb_readback/session')
        if stage=='cb_capture_progress':
            stamp=value.get('timestamp');now=int(self.clock())
            if (not integer(stamp,self.dispatched-60,4102444800) or stamp>self.dispatched+180
                    or abs(stamp-now)>60):raise ValueError('cb_readback/server_clock')
            self.server_at=stamp
        return value

    def close(self):self.grant.clear()


def run(session,native_store,store,gate,audit,*,clock=time.time,sleep=time.sleep,
        web_factory=GuardedWeb,native_factory=NativeReads):
    """Return a comparison only; never send, renew, replay, or change a journal."""
    real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (store,gate,audit))
    if real and (clock is not time.time or sleep is not time.sleep or web_factory is not GuardedWeb
                 or native_factory is not NativeReads or type(session) is not SessionStore
                 or type(native_store) is not NativeSessionStore):raise ValueError('cb_readback/override')
    state,gate_receipt=gate.read()
    if not state or state['phase']!='acknowledged' or gate_receipt is None:raise ValueError('cb_readback/no_ack')
    bundle,capture_receipt=store.read()
    if not bundle or capture_receipt is None:raise ValueError('cb_readback/capture')
    plan=bundle['plan'];saved=grant=native=None;webs=[]
    try:
        saved=session.load();grant=native_store.load(saved['vid'])
        if saved['vid']!=plan['owner']:raise ValueError('cb_readback/owner')
        original,audit_receipt,checked,checked_receipt=audit.inspect(bundle,grant,gate)
        if checked!=state or checked_receipt!=gate_receipt:raise ValueError('cb_readback/changed')
        dispatched=state['claimed_at'];last_clock=dispatched
        def current():
            return (session.load()==saved and native_store.load(saved['vid'])==grant
                    and store.read()==(bundle,capture_receipt) and gate.read()==(state,gate_receipt)
                    and audit.read()[1]==audit_receipt)
        def check_clock():
            nonlocal last_clock
            now=int(clock())
            if (not integer(now,dispatched,4102444800) or now<last_clock or now-dispatched>180
                    or day(now)!=day(dispatched)):raise ValueError('cb_readback/clock')
            last_clock=now
        if not current():raise ValueError('cb_readback/changed')
        check_clock();months=original['months']
        native=native_factory(grant,plan['book_id'],months,dispatched,current,clock)
        samples=[];catalog_stamp=None
        for index in range(3):
            if index:sleep(2)
            check_clock()
            if not current():raise ValueError('cb_readback/changed')
            web=web_factory(current);webs.append(web);web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();web.allowed={plan['book_id']}
            web.request('shelf','https://weread.qq.com/web/shelf/sync')
            sample=web.inspect(plan['book_id']);web.verify_account()
            observed=snapshot(web,sample,native,grant)
            if sample['chapter_uid']!=plan['chapter_uid'] or observed['native']['chapter_idx']!=plan['chapter_idx']:
                raise ValueError('cb_readback/source')
            if len(web.catalogs)!=2:raise ValueError('cb_readback/catalog')
            checks=[catalog_check(item,plan) for item in web.catalogs]
            if checks[0]!=checks[1] or catalog_stamp is not None and checks[0][1]!=catalog_stamp:
                raise ValueError('cb_readback/catalog')
            catalog_stamp=checks[0][1];values={}
            for month in sorted(months,key=int):
                raw=native.request('cb_readback_stats',BASE+'/readdata/detail?mode=monthly&baseTime='+month,credentials=grant)
                value=project(raw,'monthly',int(month),int(clock()))
                values[month]={key:value[key] for key in ('baseTime','readTimes','totalReadTime','readDays')}
            samples.append(dict(snapshot=observed,months=values,server_at=native.server_at))
            if save_refreshed_web_session(session,saved,web):
                fresh=session.load()
                if fresh['vid']!=saved['vid']:raise ValueError('cb_readback/owner')
                saved.clear();saved=fresh
            if not current():raise ValueError('cb_readback/changed')
            check_clock()
        if native.steps!=3*len(native.allowed) or not current():raise ValueError('cb_readback/incomplete')
        result=audit.check_acknowledged(bundle,grant,gate,samples)
        check_clock()
        if not current():raise ValueError('cb_readback/changed')
        return dict(result='CB_READBACK_MATCH',independent_samples=result['independent_samples'],
                    seconds=result['seconds'],historical_date_matched=True,
                    positions_source_shelves_and_other_counts_unchanged=True,
                    real_accounting_verified=False,account_data_posts=0,authentication_posts=0)
    finally:
        latest=next((web for web in reversed(webs) if getattr(web,'authenticated',False)),None)
        try:
            if latest and saved:save_refreshed_web_session(session,saved,latest)
        finally:
            for web in webs:
                web.samples.clear();web.progress.clear();web.catalogs.clear();web.close()
            if native:native.close()
            for item in (saved,grant):
                if isinstance(item,dict):item.clear()
