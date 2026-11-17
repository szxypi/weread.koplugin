"""Bounded, authenticated, read-only observations after a time receipt.

This module has no send, renewal, replay, or journal-transition operation.
Results are conservative comparisons, not by themselves proof of a real write.
"""
from copy import deepcopy
import time

from cloud_group_binding import Binding
from cloud_group_fixture import Journal as UploadJournal, binding
from cloud_group_journal import Journal as OldJournal
from cloud_group_nonempty_binding import Binding as NonemptyBinding
from cloud_group_nonempty_inspect import inspect,inspect_original
from cloud_group_nonempty_journal import Journal as GroupJournal
from cloud_group_old_guard import Guard
from native_time_bundle_gate import day
from readtime_upload_model import integer
from secure_weread_session import MacKeychain
from source_currentness import catalog
from synthetic_format_trial import TargetReceipt
from verify_eink_login import BASE,NativeProbe
from verify_native_statistics import StatisticsProbe,project as project_statistics
from verify_native_time_capture import XhtmlSource,xhtml_snapshot
from verify_native_time_cross_day import FilteredNative,check_capture,check_group
from verify_web_source_progress import BASE as WEB


def checked_response(probe,value):
    if not probe.report['stages'] or probe.report['stages'][-1].get('status')!=200 or not isinstance(value,dict):
        raise ValueError('bundle_readback/http')
    for key in ('errcode','errCode'):
        if key in value and value[key] is not None and (type(value[key]) is not int or value[key]!=0):
            raise ValueError('bundle_readback/api')
    if 'succ' in value and not (value['succ'] is True or type(value['succ']) is int and value['succ']==1
                                or type(value['succ']) is str and value['succ']=='1'):
        raise ValueError('bundle_readback/api')
    return value


class NativeReads(FilteredNative):
    max_reads=9
    def __init__(self,grant,plan,fixture,current,clock=time.time,opener=None):
        super().__init__(deepcopy(grant),plan['book_id'],fixture,plan['not_before'],clock,True)
        if opener is not None:self.opener=opener
        self.current=current;self.steps=0;self.server_at=None
        self.allowed=(('native_capture_progress',BASE+'/book/getProgress?bookId='+plan['book_id']),
                      ('native_capture_metadata',BASE+'/book/info?bookId='+plan['book_id']),
                      ('native_capture_shelf',BASE+'/shelf/sync'))

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if (self.steps>=9 or (stage,url)!=self.allowed[self.steps%3] or body is not None
                or credentials!=self.credentials or self.current() is not True):
            raise ValueError('bundle_readback/native_scope')
        self.steps+=1
        value=checked_response(self,super().request(stage,url,credentials=credentials,timeout=timeout))
        if self.current() is not True:raise ValueError('bundle_readback/session')
        if stage=='native_capture_progress':self.server_at=value['timestamp']
        return value


class StatisticsReads(StatisticsProbe):
    def __init__(self,grant,months,current,opener=None):
        super().__init__(opener);self.grant=deepcopy(grant);self.months=tuple(sorted(months,key=int));self.current=current;self.steps=0
        if not 1<=len(self.months)<=2 or len(set(self.months))!=len(self.months):raise ValueError('bundle_readback/months')

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        month=self.months[self.steps%len(self.months)]
        expected=BASE+'/readdata/detail?mode=monthly&baseTime='+month
        if (self.steps>=3*len(self.months) or stage!='statistics_monthly' or url!=expected or body is not None
                or credentials!=self.grant or self.current() is not True):raise ValueError('bundle_readback/statistics_scope')
        self.steps+=1
        value=checked_response(self,super().request(stage,url,credentials=credentials,timeout=timeout))
        if self.current() is not True:raise ValueError('bundle_readback/session')
        return value


class ShelfRead(NativeProbe):
    def __init__(self,grant,current,opener=None):
        super().__init__(opener);self.grant=deepcopy(grant);self.current=current;self.reads=0

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if (stage!='group_shelf' or url!=BASE+'/shelf/sync' or body is not None or credentials!=self.grant
                or self.reads>=24 or self.current() is not True):raise ValueError('bundle_readback/shelf_scope')
        self.reads+=1;value=checked_response(self,super().request(stage,url,credentials=credentials,timeout=timeout))
        if self.current() is not True:raise ValueError('bundle_readback/session')
        return value

    def shelf(self):return self.request('group_shelf',BASE+'/shelf/sync',credentials=self.grant)


def run(*,saved,grant,store,gate,audit,current,web,clock=time.time,sleep=time.sleep,
        native_factory=NativeReads,statistics_factory=StatisticsReads,shelf_factory=ShelfRead):
    """Collect exactly three independent snapshots after an acknowledged claim."""
    real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (store,gate,audit))
    if real and (clock is not time.time or sleep is not time.sleep):raise ValueError('bundle_readback/clock_override')
    if real and (native_factory is not NativeReads or statistics_factory is not StatisticsReads
                 or shelf_factory is not ShelfRead or type(web) is not XhtmlSource):
        raise ValueError('bundle_readback/transport_override')
    bundle,capture_receipt=store.read()
    if not bundle or capture_receipt is None or current() is not True:raise ValueError('bundle_readback/capture')
    plan=bundle['plan'];check_capture(plan,saved,grant,clock())
    original,audit_receipt,state,gate_receipt=audit.inspect(bundle,grant,gate)
    if state['phase']!='acknowledged':raise ValueError('bundle_readback/no_ack')
    dispatched=state['claimed_at'];last_clock=dispatched
    def fresh():
        return (current() is True and store.read()==(bundle,capture_receipt)
                and audit.read()[1]==audit_receipt and gate.read()==(state,gate_receipt))
    def check_clock():
        nonlocal last_clock
        now=int(clock())
        if (not integer(now,dispatched,4102444800) or now<last_clock or now-dispatched>180
                or day(now)!=day(dispatched)):raise ValueError('bundle_readback/clock')
        last_clock=now
    uploads,groups,old=UploadJournal(),GroupJournal(),OldJournal()
    target_receipt=TargetReceipt('epub',scope='group-fixture')
    fixture=lambda:binding(uploads,target_receipt.backend)
    upload,upload_token=fixture();group,group_token=groups.read();old_state,old_token=old.read()
    if not group or group['target']!=upload['target'] or upload['plan']['owner']!=plan['owner']:
        raise ValueError('bundle_readback/fixture')
    def state_current():
        return fresh() and fixture()==(upload,upload_token) and groups.read()==(group,group_token) and old.read()==(old_state,old_token)
    shelf=shelf_factory(grant,state_current)
    def read_pair():
        check_clock();web.verify_account()
        value={'native':shelf.shelf(),'web':web.request('shelf',WEB+'/web/shelf/sync')}
        if not state_current():raise ValueError('bundle_readback/changed')
        return value
    old_guard=Guard(old,Binding(),grant,state_current,read_pair);readonly=NonemptyBinding()
    def check_groups():
        first=inspect(groups,fixture,grant,state_current,read_pair,readonly)
        second=inspect_original(old,groups,fixture,grant,state_current,read_pair,old_guard.check,readonly)
        check_group(first,second)
    check_clock();check_groups();web.verify_account();web.prepare()
    if web.book_id!=plan['book_id'] or web.chapter!=plan['chapter_uid']:raise ValueError('bundle_readback/source')
    native=native_factory(grant,plan,upload['target'],state_current,clock)
    stats=statistics_factory(grant,original['months'],state_current)
    samples=[];catalog_stamp=None
    for index in range(3):
        if index:
            sleep(2);read=web.inspect(web.book_id)
            if (not isinstance(read,dict) or read.get('cloud_position_stable') is not True
                    or read.get('catalog_stable') is not True or web.book_id!=plan['book_id'] or web.chapter!=plan['chapter_uid']):
                raise ValueError('bundle_readback/web_changed')
        check_clock();web.verify_account()
        sample=xhtml_snapshot(web,native,grant)
        pair=getattr(web,'_time_catalog_pair',None)
        if not isinstance(pair,list) or len(pair)!=2:raise ValueError('bundle_readback/catalog')
        try:catalogs=[catalog(value,plan['book_id'],plan['chapter_uid']) for value in pair]
        except (ValueError,TypeError,KeyError,StopIteration):raise ValueError('bundle_readback/catalog') from None
        if (catalogs[0]!=catalogs[1] or catalogs[0][0]!=plan['chapter_idx']
                or catalog_stamp is not None and catalogs[0][1]!=catalog_stamp):
            raise ValueError('bundle_readback/catalog')
        catalog_stamp=catalogs[0][1]
        if not integer(native.server_at,plan['not_before'],4102444800):raise ValueError('bundle_readback/server_clock')
        months={}
        for month in sorted(original['months'],key=int):
            raw=stats.request('statistics_monthly',BASE+'/readdata/detail?mode=monthly&baseTime='+month,credentials=grant)
            value=project_statistics(raw,'monthly',int(month))
            months[month]={key:value[key] for key in ('baseTime','readTimes','totalReadTime','readDays')}
        if not state_current():raise ValueError('bundle_readback/changed')
        samples.append({'snapshot':sample,'months':months,'server_at':native.server_at});check_clock()
    if native.steps!=9 or stats.steps!=3*len(original['months']):raise ValueError('bundle_readback/incomplete')
    check_groups();web.verify_account();check_clock()
    if not state_current():raise ValueError('bundle_readback/changed')
    result=audit.check_acknowledged(bundle,grant,gate,samples)
    if not state_current():raise ValueError('bundle_readback/changed')
    return dict(result='READBACK_MATCH',independent_samples=result['independent_samples'],
                other_state_exact=result['other_counters_positions_source_shelf_exact'],
                real_accounting_verified=False,account_data_posts=0,authentication_posts=0)
