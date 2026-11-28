"""Read-only, bounded post-receipt observations for the independent capture.

No transfer, authorization renewal, or journal transition is provided here.
"""
from copy import deepcopy
import time

from cloud_group_contract import project
from native_time_bundle_gate import day
from native_time_bundle_readback import ShelfRead,StatisticsReads,checked_response
from native_time_independent_audit import IndependentAudit
from native_time_independent_broker import AccountBinding
from native_time_independent_gate import IndependentGate
from readtime_upload_model import integer
from secure_weread_session import MacKeychain
from source_currentness import catalog
from verify_eink_login import BASE
from verify_fresh_time_capture_readonly import BoundSource,TimedNative
from verify_native_statistics import project as project_statistics
from verify_native_time_capture import xhtml_snapshot
from verify_native_time_cross_day import check_capture
from verify_web_source_progress import BASE as WEB


class BoundNative(TimedNative):
    """Read exactly three progress, metadata and shelf snapshots in order."""
    def __init__(self,grant,plan,current,clock=time.time,opener=None):
        super().__init__(deepcopy(grant),plan['book_id'],clock)
        if opener is not None:self.opener=opener
        self.current=current;self.steps=0;self.server_at=None
        self.allowed=(('native_capture_progress',BASE+'/book/getProgress?bookId='+plan['book_id']),
                      ('native_capture_metadata',BASE+'/book/info?bookId='+plan['book_id']),
                      ('native_capture_shelf',BASE+'/shelf/sync'))

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if (self.steps>=9 or (stage,url)!=self.allowed[self.steps%3] or body is not None
                or credentials!=self.credentials or self.current() is not True):
            raise ValueError('independent_readback/native_scope')
        self.steps+=1
        value=checked_response(self,super().request(stage,url,credentials=credentials,timeout=timeout))
        if self.current() is not True:raise ValueError('independent_readback/session')
        if stage=='native_capture_progress':self.server_at=value['timestamp']
        return value


def run(*,saved,grant,store,gate,audit,current,clock=time.time,sleep=time.sleep,web_factory=BoundSource,
        native_factory=BoundNative,statistics_factory=StatisticsReads,shelf_factory=ShelfRead,snapshot=xhtml_snapshot):
    """Observe three accounting samples and two complete shelf pairs, once acknowledged."""
    real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (store,gate,audit))
    if not isinstance(gate,IndependentGate) or not isinstance(audit,IndependentAudit):
        raise ValueError('independent_readback/scope')
    if real and (not gate._real or not audit._real or not isinstance(getattr(store,'backend',None),MacKeychain)
            or type(current) is not AccountBinding or not current.matches(grant,saved.get('cookies'))
            or clock is not time.time or sleep is not time.sleep or web_factory is not BoundSource
            or native_factory is not BoundNative or statistics_factory is not StatisticsReads
            or shelf_factory is not ShelfRead or snapshot is not xhtml_snapshot):
        raise ValueError('independent_readback/override')
    bundle,capture_receipt=store.read()
    if not bundle or capture_receipt is None or current() is not True:raise ValueError('independent_readback/capture')
    plan=bundle['plan'];check_capture(plan,saved,grant,clock())
    packet,audit_receipt,state,gate_receipt=audit.inspect(bundle,grant,gate)
    if state['phase']!='acknowledged':raise ValueError('independent_readback/no_ack')
    dispatched=state['claimed_at'];last_clock=dispatched
    def fresh():
        return (current() is True and store.read()==(bundle,capture_receipt)
                and audit.read()[1]==audit_receipt and gate.read()==(state,gate_receipt))
    def check_clock():
        nonlocal last_clock
        now=int(clock())
        if (not integer(now,dispatched,4102444800) or now<last_clock or now-dispatched>180
                or day(now)!=day(dispatched)):raise ValueError('independent_readback/clock')
        last_clock=now
    web=web_factory(plan['book_id'])
    try:
        web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        shelf=shelf_factory(grant,fresh)
        def read_pair():
            check_clock();web.verify_account()
            pair={'native':shelf.shelf(),'web':web.request('shelf',WEB+'/web/shelf/sync')}
            if any(project(pair[key])['members'].count(plan['book_id'])!=1 for key in ('native','web')):
                raise ValueError('independent_readback/shelf')
            if not fresh():raise ValueError('independent_readback/changed')
            return pair
        observations=[read_pair()]
        web.verify_account();web.prepare()
        if web.book_id!=plan['book_id'] or web.chapter!=plan['chapter_uid']:
            raise ValueError('independent_readback/source')
        native=native_factory(grant,plan,fresh,clock);stats=statistics_factory(grant,packet['baseline']['months'],fresh)
        samples=[]
        for index in range(3):
            if index:
                sleep(2);value=web.inspect(web.book_id)
                if (not isinstance(value,dict) or value.get('cloud_position_stable') is not True
                        or value.get('catalog_stable') is not True or web.book_id!=plan['book_id']
                        or web.chapter!=plan['chapter_uid']):raise ValueError('independent_readback/source')
            check_clock();web.verify_account();sample=snapshot(web,native,grant)
            pair=getattr(web,'_time_catalog_pair',None)
            if not isinstance(pair,list) or len(pair)!=2:raise ValueError('independent_readback/catalog')
            try:catalogs=[catalog(value,plan['book_id'],plan['chapter_uid']) for value in pair]
            except (ValueError,TypeError,KeyError,StopIteration):raise ValueError('independent_readback/catalog') from None
            if (catalogs[0]!=catalogs[1] or catalogs[0][0]!=plan['chapter_idx']
                    or catalogs[0][1]!=packet['catalog_stamp']):raise ValueError('independent_readback/catalog')
            if not integer(native.server_at,plan['not_before'],4102444800):raise ValueError('independent_readback/server_clock')
            months={}
            for month in sorted(packet['baseline']['months'],key=int):
                raw=stats.request('statistics_monthly',BASE+'/readdata/detail?mode=monthly&baseTime='+month,credentials=grant)
                value=project_statistics(raw,'monthly',int(month))
                months[month]={key:value[key] for key in ('baseTime','readTimes','totalReadTime','readDays')}
            if not fresh():raise ValueError('independent_readback/changed')
            samples.append({'snapshot':sample,'months':months,'server_at':native.server_at});check_clock()
        if native.steps!=9 or stats.steps!=3*len(packet['baseline']['months']):raise ValueError('independent_readback/incomplete')
        observations.append(read_pair());web.verify_account();check_clock()
        if not fresh():raise ValueError('independent_readback/changed')
        result=audit.assess_acknowledged(bundle,grant,gate,samples,observations)
        if not fresh():raise ValueError('independent_readback/changed')
        if result['full_shelf_exact'] is False:
            partial=dict(result='READBACK_PARTIAL',independent_samples=result['independent_samples'],
                         accounting_and_core_state_exact=result['other_counters_positions_source_shelf_exact'],
                         full_shelf_exact=False,real_accounting_verified=False,account_data_posts=0,authentication_posts=0,
                         component_diagnosis_available=result['component_diagnosis_available'])
            if result['component_diagnosis_available']:
                partial.update(native_shelf_change=result['native_shelf_change'],web_shelf_change=result['web_shelf_change'])
            return partial
        return dict(result='READBACK_MATCH',independent_samples=result['independent_samples'],other_state_exact=True,
                    full_shelf_exact=True,real_accounting_verified=False,account_data_posts=0,authentication_posts=0)
    finally:
        web.shards.clear()
        if hasattr(web,'_time_catalog_pair'):web._time_catalog_pair.clear()
        web.close()
