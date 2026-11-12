"""Native TXT position hypothesis and scoped one-shot transport boundaries."""
from contextlib import redirect_stdout,ExitStack
from copy import deepcopy
import io
import json
import time
import unittest
from unittest.mock import Mock,patch
from test_secure_native_session import credentials,Backend
from secure_native_txt_position import NativeTxtPositionStore
from secure_txt_zero_time import TxtZeroTimeStore
from secure_weread_session import StoreError
from txt_full_summary import digest
from native_txt_read_model import body
from verify_native_txt_position import Native,compare,inspect
import verify_native_txt_same_point as task


def point():return dict(book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='synthetic full summary')
def progress():return dict(book=dict(bookId='41',chapterUid=2,chapterIdx=3,chapterOffset=12,progress=17,summary='synthetic full summary',readingTime=40,recordReadingTime=50,ttsTime=0))
def bound():return dict(protocol=NativeTxtPositionStore.protocol,**{k:'a'*64 for k in ('owner_sha256','source_sha256','baseline_sha256','grant_sha256','shelf_sha256','request_sha256')})
def payload():return body(credentials(),point(),0,'5ecdcfd7f',int(time.time()),123,'+08:00')


class NativeTxtTests(unittest.TestCase):
    def execute(self,ack=None,apply=True,readback_error=None):
        web=Mock();web.book_id='41';web.vid='900000';web.sample={'plain':'synthetic source'}
        saved=dict(vid=web.vid,cookies={});session=Mock();session.load.side_effect=lambda:deepcopy(saved)
        grant=credentials();native=task.Probe(grant,'41');store=NativeTxtPositionStore(Backend());report={}
        value=payload();plan={'baseline':point()};observation=dict(version=0,counts={'readingTime':40})
        def readback(*args):
            if readback_error and native.posts:raise ValueError(readback_error)
        def send(*args,**kwargs):
            if isinstance(ack,Exception):raise ack
            return {'succ':1} if ack is None else ack
        with patch.object(task,'prepare',return_value=(plan,observation,'a'*64,value)),\
             patch.object(task,'save_refreshed_web_session'),patch.object(task,'exact',side_effect=readback),\
             patch.object(task,'NativeSessionStore') as grant_store,patch('verify_eink_login.NativeProbe.request',side_effect=send):
            grant_store.return_value.load.return_value=deepcopy(grant)
            try:task.run(web,native,grant,session,saved,store,report,apply)
            except Exception:report['stopped']=True
        return store,native,report
    def test_verified_receipt_and_unchanged_readback_retire_one_request(self):
        store,native,report=self.execute()
        self.assertEqual(native.posts,1);self.assertEqual(store.read()[0]['phase'],'retired')
        self.assertEqual(report['result'],'NATIVE_TXT_SAME_POINT_PROTOCOL_VERIFIED')
        self.assertTrue(report['time_counters_unchanged']);self.assertFalse(store.pending())
    def test_unknown_receipt_or_lost_response_remains_pending_without_replay(self):
        for ack in ({},ValueError('synthetic lost response')):
            with self.subTest(ack=type(ack).__name__):
                store,native,report=self.execute(ack)
                self.assertEqual(native.posts,1);self.assertTrue(report['original_readback'])
                self.assertTrue(report['stopped']);self.assertEqual(store.read()[0]['phase'],'same_pending')
    def test_changed_counters_or_position_cannot_retire_even_with_success_receipt(self):
        for error in ('native_txt/time_changed','native_txt/web_changed','native_txt/shelf_changed'):
            with self.subTest(error=error):
                store,native,report=self.execute(readback_error=error)
                self.assertEqual(native.posts,1);self.assertTrue(report['stopped']);self.assertTrue(store.pending())
    def test_readonly_plan_does_not_reserve_or_dispatch(self):
        store,native,report=self.execute(apply=False)
        self.assertEqual(native.posts,0);self.assertEqual(store.read(),(None,None))
        self.assertEqual(report['result'],'NATIVE_TXT_SAME_POINT_PLAN_VERIFIED')
    def test_shared_barrier_excludes_only_own_intent_during_resolution(self):
        import verify_native_thought_trial as shared
        factories=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore',
            'NativeShelfTrialStore','NativeFinishTrialStore','FlagTrialStore','NativeFlagTrialStore','TxtFullSummaryStore',
            'TxtZeroTimeStore','NativeTxtPositionStore','NativeTxtRoundtripStore','InitialMarkStyleStore','NonemptyMarksStore','ReadtimeTrialStore',
            'MarkColorStore','MarkStyleTrialStore','BookmarkTrialStore','HighlightTrialStore')
        with ExitStack() as stack:
            mocks={name:stack.enter_context(patch.object(shared,name)) for name in factories}
            for factory in mocks.values():
                factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None)
            mocks['NativeTxtPositionStore'].return_value.pending.return_value=True
            self.assertTrue(shared.other_pending());self.assertFalse(shared.other_pending(exclude_native_txt=True))
            for name in ('TxtFullSummaryStore','TxtZeroTimeStore','FlagTrialStore'):
                mocks[name].return_value.pending.return_value=True
                self.assertTrue(shared.other_pending(exclude_native_txt=True))
                mocks[name].return_value.pending.return_value=False
    def test_independent_moon_signature_vector_zero_time_and_zero_version(self):
        value=body(credentials(),point(),0,'5ecdcfd7f',1700000000,123,'+08:00')
        # Executed original Moon 43b2181 app.lua readBody in the official Lua runtime.
        self.assertEqual(value['signature'],'6a97d1c459c91c2bfb68769d0fa1e7ba72ac128faa3574aa76ce31686baf64a2')
        self.assertEqual(value['hours'],[]);self.assertEqual(value['readingTime'],0);self.assertEqual(value['ttsTime'],0)
        self.assertNotIn('isResendReadingInfo',value);self.assertNotIn('chapterProgress',value)
    def test_full_summary_and_explicit_chapter_progress_are_not_inferred(self):
        p=dict(point(),summary='合成摘要'*20);value=body(credentials(),p,0,'guest',1700000000,0,'+08:00',12.5)
        self.assertEqual(value['summary'],p['summary']);self.assertEqual(value['chapterProgress'],12.5)
    def test_invalid_coordinates_summary_and_parameters_are_rejected(self):
        for field,value in (('chapter_offset',-1),('chapter_idx',True),('chapter_uid','0'),('chapter_uid',str(2**53)),('raw_percent',float('nan')),('summary','bad\0'),('summary','x'*513)):
            with self.subTest(field=field),self.assertRaises(ValueError):body(credentials(),dict(point(),**{field:value}),0,'guest',1700000000,0,'+08:00')
        with self.assertRaises(ValueError):body(credentials(),point(),True,'guest',1700000000,0,'+08:00')
    def test_readonly_probe_rejects_writes_wrong_owner_and_unlisted_routes(self):
        probe=Native(credentials(),'41')
        for url,data,grant in ((task.BASE+'/book/read',{},credentials()),(task.BASE+'/book/getProgress?bookId=42',None,credentials()),
                               (task.BASE+'/config?token=1',None,dict(credentials(),vid='900001'))):
            with self.assertRaises(ValueError):probe.request('test',url,data,grant)
    def test_native_web_agreement_requires_all_position_fields_and_full_summary(self):
        source=dict(baseline=point());_p,counters=compare(source,progress(),'41');self.assertEqual(counters['readingTime'],40)
        for field,value in (('summary','changed'),('chapterOffset',13),('progress',18),('readingTime',True)):
            p=progress();p['book'][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):compare(source,p,'41')
    def test_live_zero_version_is_explicit_and_positive_versions_must_match(self):
        for native_version,web_version,allowed in ((0,None,True),(7,7,True),(0,7,False),(7,None,False),(7,8,False),(1,True,False),(7,7.0,False)):
            with self.subTest(native=native_version,web=web_version):
                web=Mock();web.book_id='41';web.sample={'record':{'book':{}}}
                if web_version is not None:web.sample['record']['book']['bookVersion']=web_version
                metadata=dict(bookId='41',version=native_version);native=Mock()
                native.request.side_effect=[progress(),metadata,{'token':'synthetic-config'},{'feature':{}},metadata,progress()]
                report={}
                if allowed:
                    observation=inspect(web,native,credentials(),{'baseline':point()},report)
                    self.assertEqual(observation['version'],native_version)
                    self.assertEqual(report['book_version_matched'],native_version>0)
                    self.assertEqual(report['unversioned_native_zero'],native_version==0)
                else:
                    with self.assertRaises(ValueError):inspect(web,native,credentials(),{'baseline':point()},report)
    def test_conflicting_metadata_aliases_or_outer_catalog_versions_are_rejected(self):
        for kind in ('native_alias','outer_catalog','metadata_changed'):
            with self.subTest(kind=kind):
                web=Mock();web.book_id='41';web.sample={'record':{'book':{}}}
                metadata=dict(bookId='41',version=0);later=deepcopy(metadata)
                if kind=='native_alias':metadata['bookVersion']=1
                elif kind=='outer_catalog':web.sample['record']['version']=7
                else:later['version']=1
                native=Mock();native.request.side_effect=[progress(),metadata,{'token':'synthetic-config'},{'feature':{}},later,progress()]
                with self.assertRaisesRegex(ValueError,'native_txt/version'):inspect(web,native,credentials(),{'baseline':point()},{})
    def test_fresh_readback_checks_native_web_summary_counters_and_shelf(self):
        web=Mock();web.book_id='41';native=Mock();native.request.return_value=progress()
        web.request.side_effect=[progress(),{'books':[]}]
        with patch.object(task,'state_hash',return_value='a'*64):
            task.exact(web,native,credentials(),{'baseline':point()},{'readingTime':40,'recordReadingTime':50,'ttsTime':0},'a'*64)
        web.request.side_effect=None;web.request.return_value=progress()
        with self.assertRaisesRegex(ValueError,'native_txt/time_changed'):
            task.exact(web,native,credentials(),{'baseline':point()},{'readingTime':41,'recordReadingTime':50,'ttsTime':0},'a'*64)
        web.request.return_value=progress();web.request.return_value['book']['summary']='changed'
        with self.assertRaisesRegex(ValueError,'native_txt/web_changed'):
            task.exact(web,native,credentials(),{'baseline':point()},{'readingTime':40,'recordReadingTime':50,'ttsTime':0},'a'*64)
    def test_transport_claim_precedes_exact_one_request(self):
        probe=task.Probe(credentials(),'41');value=payload();probe.pending=digest(value);events=[];probe.claim=lambda:events.append('claim')
        with patch('verify_eink_login.NativeProbe.request',side_effect=lambda *a,**k:events.append('http') or dict(succ=1)) as transport:
            self.assertEqual(probe.request('native_txt_same',task.BASE+'/book/read',value,credentials()),dict(succ=1))
            with self.assertRaises(ValueError):probe.request('native_txt_same',task.BASE+'/book/read',value,credentials())
        self.assertEqual(events,['claim','http']);self.assertEqual(transport.call_count,1)
    def test_changed_body_stale_clock_or_claim_failure_never_dispatches(self):
        for kind in ('changed','stale','claim'):
            probe=task.Probe(credentials(),'41');value=payload();probe.pending=digest(value);probe.claim=Mock()
            if kind=='changed':value['chapterOffset']+=1
            elif kind=='stale':value['timestamp']-=31;probe.pending=digest(value)
            else:probe.claim.side_effect=StoreError('synthetic failure')
            with patch('verify_eink_login.NativeProbe.request') as request,self.assertRaises((ValueError,StoreError)):
                probe.request('native_txt_same',task.BASE+'/book/read',value,credentials())
            request.assert_not_called();self.assertEqual(probe.posts,0)
    def test_lost_response_is_claimed_once_and_not_replayable(self):
        probe=task.Probe(credentials(),'41');value=payload();probe.pending=digest(value);probe.claim=Mock()
        with patch('verify_eink_login.NativeProbe.request',side_effect=ValueError('lost')) as transport:
            for _i in range(2):
                with self.assertRaises(ValueError):probe.request('native_txt_same',task.BASE+'/book/read',value,credentials())
        self.assertEqual(probe.posts,1);self.assertEqual(transport.call_count,1);probe.claim.assert_called_once()
    def test_distinct_scope_and_terminal_tombstone(self):
        backend=Backend();store=NativeTxtPositionStore(backend);r=store.reserve(bound())
        with self.assertRaises(StoreError):TxtZeroTimeStore(backend).read()
        r=store.advance(r,'prepared','same_pending');store.advance(r,'same_pending','retired')
        self.assertFalse(store.pending())
        with self.assertRaises(StoreError):store.reserve(bound())
    def test_default_is_offline_and_never_loads_credentials(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)


if __name__=='__main__':unittest.main()
