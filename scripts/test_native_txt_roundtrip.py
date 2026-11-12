"""Source-backed TXT window and durable adjacent/restore transaction tests."""
from contextlib import ExitStack,redirect_stdout
from copy import deepcopy
import io
import json
import time
import unittest
from unittest.mock import Mock,patch
from test_secure_native_session import credentials,Backend
from secure_weread_session import StoreError
from secure_native_txt_roundtrip import NativeTxtRoundtripStore,POINT_FIELDS,validate_plan
from secure_native_txt_position import NativeTxtPositionStore
from txt_cloud_position import prepare as source_plan
from native_txt_summary import prepare as slide
from txt_full_summary import digest
from native_txt_read_model import body
from verify_source_coordinates import CoordinateError
import verify_native_txt_roundtrip as task

RAW='\ufeff标题\r\n甲乙丙丁戊己庚辛壬癸\r\n\u3000\u3000子丑寅卯辰巳午未申酉戌亥天地玄黄宇宙洪荒日月盈昃辰宿列张'
OBSERVED='甲乙丙丁戊己庚辛壬癸 \n子丑寅卯辰巳午未申酉戌亥天地玄黄宇宙'


def fixture(raw=RAW,observed=OBSERVED):
    co=len(raw[:raw.index('甲')].encode('utf-16-le'))//2
    progress=dict(book=dict(bookId='41',chapterUid=2,chapterIdx=3,chapterOffset=co,progress=12,summary=observed))
    return source_plan(raw,progress,dict(book_id='41',psvts='synthetic',progress=deepcopy(progress)),[dict(chapterUid=2,chapterIdx=3)],'41')


def plan():
    p=slide(RAW,fixture());return dict(protocol=NativeTxtRoundtripStore.protocol,owner_sha256=digest('900000'),grant_sha256=digest(credentials()),
        source_sha256='a'*64,shelf_sha256='b'*64,catalog_sha256='c'*64,baseline=task.compact(p['baseline']),target=task.compact(p['target']),
        counts=dict(readingTime=40,recordReadingTime=50,ttsTime=0),version=0,chapter_progress=None)


class SummaryTests(unittest.TestCase):
    def test_exact_observed_whitespace_is_retained_in_full_adjacent_summary(self):
        source=fixture();self.assertFalse(source['source_summary_matches']);value=slide(RAW,source)
        self.assertEqual(value['target']['chapter_offset'],value['baseline']['chapter_offset']+1)
        self.assertEqual(value['target']['summary'],OBSERVED[1:]+'洪')
        self.assertEqual(len(value['target']['summary']),len(OBSERVED));self.assertIn(' \n',value['target']['summary'])
        self.assertEqual(value['baseline']['summary'],OBSERVED);self.assertTrue(value['preserved_internal_whitespace'])
    def test_unknown_whitespace_combining_control_or_end_at_new_boundary_is_rejected(self):
        for suffix in ('\r\n洪','\t洪','\u0301洪','\x00洪',''):
            raw=RAW[:RAW.index('洪')]+suffix
            with self.subTest(suffix=repr(suffix)),self.assertRaises((ValueError,CoordinateError)):slide(raw,fixture(raw))
    def test_unverified_summary_start_leading_or_trailing_space_is_rejected(self):
        for summary in (' '+OBSERVED,OBSERVED+' ',OBSERVED.replace('甲','乙',1)):
            with self.subTest(summary=summary),self.assertRaises(ValueError):slide(RAW,fixture(observed=summary))
    def test_unavailable_target_wrong_basis_or_changed_offset_is_rejected(self):
        for mutate in (lambda p:p.update(target=None),lambda p:p.update(basis='other'),lambda p:p['target'].update(chapter_offset=999)):
            p=fixture();mutate(p)
            with self.assertRaises(ValueError):slide(RAW,p)
    def test_surrogate_at_current_point_cannot_be_one_utf16_unit(self):
        raw=RAW.replace('甲','😀',1);co=len(raw[:raw.index('😀')].encode('utf-16-le'))//2
        progress=dict(book=dict(bookId='41',chapterUid=2,chapterIdx=3,chapterOffset=co,progress=12,summary=OBSERVED.replace('甲','😀',1)))
        p=source_plan(raw,progress,dict(book_id='41',psvts='synthetic',progress=deepcopy(progress)),[dict(chapterUid=2,chapterIdx=3)],'41')
        self.assertIsNone(p['target'])
        with self.assertRaises(ValueError):slide(raw,p)


class StorageTests(unittest.TestCase):
    def test_new_instance_recovers_complete_original_summary_and_target_from_backend(self):
        backend=Backend();store=NativeTxtRoundtripStore(backend);r=store.reserve(plan())
        r=store.advance(r,'prepared','advance_pending');fresh=NativeTxtRoundtripStore(backend)
        state,_r=fresh.read();self.assertEqual(state['plan']['baseline'],plan()['baseline'])
        self.assertEqual(state['plan']['target'],plan()['target']);self.assertTrue(fresh.pending())
        self.assertNotIn(OBSERVED,repr(r))
    def test_consumed_tombstone_rejects_relaunch_and_old_one_slot_protocol(self):
        backend=Backend();store=NativeTxtRoundtripStore(backend);r=store.reserve(plan())
        with self.assertRaises(StoreError):NativeTxtPositionStore(backend).read()
        for before,after in (('prepared','advance_pending'),('advance_pending','advance_acknowledged'),('advance_acknowledged','advance_verified'),
                ('advance_verified','restore_pending'),('restore_pending','restore_acknowledged'),('restore_acknowledged','retired')):r=store.advance(r,before,after)
        self.assertEqual(store.read()[0]['posts'],2);self.assertFalse(store.pending())
        with self.assertRaises(StoreError):store.reserve(plan())
    def test_changed_point_summary_count_or_version_cannot_be_reserved(self):
        for mutate in (lambda p:p['target'].update(chapter_offset=p['baseline']['chapter_offset']+2),lambda p:p['target'].update(summary='changed'),
                       lambda p:p['baseline'].update(extra=True),lambda p:p.update(version=True),lambda p:p['counts'].update(readingTime=-1)):
            p=plan();mutate(p)
            with self.assertRaises((StoreError,ValueError)):NativeTxtRoundtripStore(Backend()).reserve(p)
    def test_stale_receipt_and_skipped_stage_never_claim_restore(self):
        store=NativeTxtRoundtripStore(Backend());r=store.reserve(plan());next_r=store.advance(r,'prepared','advance_pending')
        with self.assertRaises(StoreError):store.advance(r,'advance_pending','advance_verified')
        with self.assertRaises(StoreError):store.advance(next_r,'advance_pending','retired')
        self.assertEqual(store.read()[0]['posts'],1)
    def test_unreadable_save_stops_before_dispatch_and_retains_unknown_backend(self):
        backend=Backend();store=NativeTxtRoundtripStore(backend)
        with patch.object(backend,'load',side_effect=[None,None]),self.assertRaises(StoreError):store.reserve(plan())
        self.assertIsNotNone(backend.data);self.assertTrue(store.pending())


class WorkflowTests(unittest.TestCase):
    def execute(self,acks=None,apply=True,break_before_restore=False,store=None,restore_only=False,resolving=False,changed_grant=False,break_target=False):
        web=Mock();web.book_id='41';web.vid='900000';web.inspect_plan.return_value={'baseline':plan()['target']}
        session=Mock();session.load.return_value={'vid':'900000','cookies':{}}
        native=task.Probe(credentials(),'41',restore_only=restore_only);store=store or NativeTxtRoundtripStore(Backend());report={};events=[]
        replies=iter(acks or [{'succ':1},{'succ':1}])
        def check(*args,**kwargs):
            if break_before_restore and native.posts==1 and kwargs.get('refresh'):raise ValueError('synthetic source changed')
            if break_target and native.posts==1 and not kwargs.get('refresh'):raise ValueError('synthetic target changed')
        def send(*args,**kwargs):
            events.append(store.read()[0]['phase']);value=next(replies)
            if isinstance(value,Exception):raise value
            return value
        with patch.object(task,'make_plan',return_value=(plan(),'synthetic-guest')),patch.object(task,'check',side_effect=check),\
             patch.object(task,'settle',side_effect=lambda web,native,grant,p,expected,before,r,stage,ack:check(web,native,grant,p,expected)),\
             patch.object(task,'inspect',return_value=dict(version=0,guest='synthetic-guest')),patch.object(task,'save_refreshed_web_session'),\
             patch.object(task,'NativeSessionStore') as grants,patch('verify_eink_login.NativeProbe.request',side_effect=send):
            grants.return_value.load.return_value=credentials()
            if changed_grant:grants.return_value.load.side_effect=[credentials(),dict(credentials(),accessToken='synthetic-new-grant')]
            try:task.run(web,native,credentials(),session,session.load(),store,report,apply=apply,restore_only=restore_only,resolving=resolving)
            except Exception:report['stopped']=True
        return store,native,report,events
    def test_explicit_successes_and_independent_readbacks_retire_exactly_two_slots(self):
        store,native,report,events=self.execute()
        self.assertEqual(events,['advance_pending','restore_pending']);self.assertEqual(native.posts,2)
        self.assertTrue(report['target_readback']);self.assertTrue(report['original_readback'])
        self.assertEqual(report['result'],'NATIVE_TXT_ADJACENT_RESTORE_PROTOCOL_VERIFIED');self.assertFalse(store.pending())
    def test_plan_only_does_not_reserve_or_dispatch(self):
        store,native,report,events=self.execute(apply=False)
        self.assertEqual(store.read(),(None,None));self.assertEqual(native.posts,0);self.assertEqual(events,[])
    def test_unknown_advance_receipt_or_transport_loss_never_automatically_restores(self):
        for response in ({},ValueError('synthetic timeout')):
            store,native,report,events=self.execute([response])
            self.assertTrue(report['stopped']);self.assertEqual(events,['advance_pending']);self.assertEqual(native.posts,1)
            self.assertEqual(store.read()[0]['phase'],'advance_pending')
    def test_restore_loss_cannot_replay_either_step(self):
        store,native,report,events=self.execute([{'succ':1},ValueError('synthetic timeout')])
        self.assertTrue(report['stopped']);self.assertEqual(native.posts,2);self.assertEqual(store.read()[0]['phase'],'restore_pending')
        _store,fresh,result,requests=self.execute(store=store,restore_only=True)
        self.assertEqual(fresh.posts,0);self.assertTrue(result['stopped']);self.assertEqual(requests,[])
    def test_grant_change_before_claim_aborts_without_a_post(self):
        store,native,report,events=self.execute(changed_grant=True)
        self.assertTrue(report['stopped']);self.assertEqual(native.posts,0);self.assertEqual(events,[])
        self.assertEqual(store.read()[0]['phase'],'aborted')
    def test_changed_target_after_success_receipt_stops_before_restore(self):
        store,native,report,events=self.execute(break_target=True)
        self.assertTrue(report['stopped']);self.assertEqual(native.posts,1);self.assertEqual(events,['advance_pending'])
        self.assertEqual(store.read()[0]['phase'],'advance_acknowledged');self.assertNotIn('target_readback',report)
    def test_source_change_between_steps_stops_and_fresh_process_restores_only(self):
        store,native,report,events=self.execute(break_before_restore=True)
        self.assertEqual(native.posts,1);self.assertEqual(store.read()[0]['phase'],'advance_verified')
        _store,fresh,result,requests=self.execute(store=store,restore_only=True)
        self.assertEqual(fresh.posts,1);self.assertEqual(requests,['restore_pending'])
        self.assertEqual(result['result'],'NATIVE_TXT_ORIGINAL_RESTORED_ONCE');self.assertFalse(store.pending())
    def test_unconfirmed_advance_can_only_use_unused_restore_slot_after_fresh_checks(self):
        store,_native,_report,_events=self.execute([{}])
        _store,fresh,report,events=self.execute(store=store,restore_only=True)
        self.assertEqual(fresh.posts,1);self.assertFalse(report['prior_advance_success_claimed']);self.assertTrue(report['original_restoration_verified'])
        self.assertEqual(store.read()[0]['phase'],'restored_advance_unverified')
    def test_readonly_resolution_never_claims_protocol_success_or_sends(self):
        store,_native,_report,_events=self.execute([{}])
        _store,fresh,report,events=self.execute(store=store,resolving=True)
        self.assertEqual(fresh.posts,0);self.assertEqual(events,[]);self.assertFalse(report['prior_roundtrip_success_claimed'])
        self.assertEqual(store.read()[0]['phase'],'closed_advance_unverified')
    def test_saved_restore_ack_can_finish_after_readonly_settlement_without_replay(self):
        store=NativeTxtRoundtripStore(Backend());r=store.reserve(plan())
        for before,after in (('prepared','advance_pending'),('advance_pending','advance_acknowledged'),('advance_acknowledged','advance_verified'),
                ('advance_verified','restore_pending'),('restore_pending','restore_acknowledged')):r=store.advance(r,before,after)
        _store,native,report,events=self.execute(store=store,resolving=True)
        self.assertEqual(native.posts,0);self.assertEqual(events,[]);self.assertTrue(report['prior_roundtrip_success_claimed'])
        self.assertEqual(store.read()[0]['phase'],'retired')
    def test_wrong_owner_cannot_resolve_private_target(self):
        store=NativeTxtRoundtripStore(Backend());p=plan();p['owner_sha256']='f'*64;store.reserve(p)
        _store,native,report,events=self.execute(store=store,resolving=True)
        self.assertTrue(report['stopped']);self.assertEqual(native.posts,0);self.assertEqual(events,[])
    def test_direct_default_is_offline_and_private_errors_are_not_emitted(self):
        with patch.object(task,'SessionStore') as sessions,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        sessions.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)
        with patch('verify_native_thought_trial.other_pending',return_value=False),patch.object(task,'NativeTxtRoundtripStore'),\
             patch.object(task,'SessionStore',side_effect=ValueError('synthetic private secret')),redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main(['--saved-session']),1)
        self.assertNotIn('synthetic private secret',out.getvalue())


class DispatchTests(unittest.TestCase):
    def setup_probe(self):
        probe=task.Probe(credentials(),'41');value=body(credentials(),plan()['target'],0,'synthetic-guest',int(time.time()),123,'+08:00')
        probe.pending=digest(value);probe.claim=Mock();return probe,value
    def test_invalid_route_stage_grant_or_clock_rejected_before_claim(self):
        for kind in ('route','stage','grant','clock','body'):
            probe,value=self.setup_probe();stage='native_txt_advance';url=task.BASE+'/book/read';grant=credentials()
            if kind=='route':url+='/other'
            elif kind=='stage':stage='native_txt_restore'
            elif kind=='grant':grant['vid']='900001'
            elif kind=='clock':value['timestamp']-=31;probe.pending=digest(value)
            else:value['readingTime']=1
            with patch('verify_eink_login.NativeProbe.request') as request,self.assertRaises(ValueError):probe.request(stage,url,value,grant)
            probe.claim.assert_not_called();request.assert_not_called()
    def test_failed_durable_claim_never_dispatches(self):
        probe,value=self.setup_probe();probe.claim.side_effect=StoreError('synthetic failed save')
        with patch('verify_eink_login.NativeProbe.request') as request,self.assertRaises(StoreError):probe.request('native_txt_advance',task.BASE+'/book/read',value,credentials())
        request.assert_not_called();self.assertEqual(probe.posts,0)
    def test_shared_barrier_can_exclude_only_own_pending_scope(self):
        import verify_native_thought_trial as shared
        names=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore','NativeShelfTrialStore','NativeFinishTrialStore',
            'FlagTrialStore','NativeFlagTrialStore','TxtFullSummaryStore','TxtZeroTimeStore','NativeTxtPositionStore','NativeTxtRoundtripStore','RawTxtExcerptStore','NativeReaderTrialStore','InitialMarkStyleStore',
            'NonemptyMarksStore','ReadtimeTrialStore','MarkColorStore','MarkStyleTrialStore','BookmarkTrialStore','HighlightTrialStore')
        with ExitStack() as stack:
            factories={name:stack.enter_context(patch.object(shared,name)) for name in names}
            for factory in factories.values():factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None)
            factories['NativeTxtRoundtripStore'].return_value.pending.return_value=True
            ordinary=factories['NativeTxtRoundtripStore'].return_value;native=Mock();native.pending.return_value=False
            factories['NativeTxtRoundtripStore'].side_effect=lambda *args,**kwargs:native if kwargs.get('native') else ordinary
            self.assertTrue(shared.other_pending());self.assertFalse(shared.other_pending(exclude_native_txt_roundtrip=True))
            for name in ('NativeTxtPositionStore','TxtFullSummaryStore','TxtZeroTimeStore','NativeFlagTrialStore'):
                factories[name].return_value.pending.return_value=True;self.assertTrue(shared.other_pending(exclude_native_txt_roundtrip=True))
                factories[name].return_value.pending.return_value=False
            native.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_native_txt_roundtrip=True))
            ordinary.pending.return_value=False
            self.assertFalse(shared.other_pending(exclude_native_txt_flow=True))


class FreshStateTests(unittest.TestCase):
    def fixture(self):
        web=Mock();web.vid='900000';web.book_id='41';web.sample=dict(plain=RAW,record={'book':{'bookId':'41','format':'txt'}},chapters=[dict(chapterUid=2,chapterIdx=3)])
        web.find_sample.return_value=True;web.inspect_plan.return_value=fixture()
        p=plan();p['source_sha256']=task.source_hash(web);p['catalog_sha256']=task.catalog_hash(web)
        native=Mock();progress=dict(book=dict(bookId='41',chapterUid=2,chapterIdx=3,chapterOffset=p['baseline']['chapter_offset'],progress=12,summary=OBSERVED,**p['counts']))
        native.request.side_effect=[{'bookId':'41','version':0},progress];web.request.side_effect=[progress,{'books':[]}]
        return web,native,p,progress
    def test_fresh_source_native_metadata_and_two_transport_positions_are_verified(self):
        web,native,p,_progress=self.fixture()
        with patch('verify_native_txt_same_point.state_hash',return_value=p['shelf_sha256']):task.check(web,native,credentials(),p,p['baseline'],refresh=True)
        web.find_sample.assert_called_once_with(book_id='41');self.assertEqual(native.request.call_count,2)
    def test_missing_content_or_source_change_or_metadata_bool_is_refused(self):
        for kind in ('missing','source','version','point'):
            web,native,p,progress=self.fixture()
            if kind=='missing':web.find_sample.return_value=False
            elif kind=='source':p['source_sha256']='f'*64
            elif kind=='version':native.request.side_effect=[{'bookId':'41','version':False},progress]
            else:web.inspect_plan.return_value['baseline']['chapter_offset']+=1
            with self.subTest(kind=kind),self.assertRaises(ValueError):task.check(web,native,credentials(),p,p['baseline'],refresh=True)
    def test_changed_time_counter_cannot_pass_fresh_readback(self):
        web,native,p,progress=self.fixture();progress['book']['readingTime']+=1
        with self.assertRaisesRegex(ValueError,'native_txt/time_changed'):task.check(web,native,credentials(),p,p['baseline'],refresh=True)
    def test_catalog_identity_version_and_chapters_are_bound_but_social_metadata_is_not(self):
        web,_native,p,_progress=self.fixture();before=task.catalog_hash(web)
        web.sample['record']['book']['readingTime']=999;self.assertEqual(before,task.catalog_hash(web))
        web.sample['record']['book']['bookVersion']=1;self.assertNotEqual(before,task.catalog_hash(web))


class SettlementTests(unittest.TestCase):
    def test_known_before_state_can_be_observed_then_expected_without_reposting(self):
        report={}
        with patch.object(task,'snapshot',side_effect=[False,False,True]) as read,patch.object(task.time,'sleep') as sleep,\
             patch('verify_eink_login.NativeProbe.request') as transport:
            task.settle(None,None,None,plan(),plan()['target'],plan()['baseline'],report,'advance',True)
        self.assertEqual(read.call_count,3);self.assertEqual(sleep.call_count,2);transport.assert_not_called()
        self.assertEqual(report['readback_attempts']['advance'],3)
    def test_readonly_wait_has_four_attempt_limit(self):
        with patch.object(task,'snapshot',return_value=False) as read,patch.object(task.time,'sleep') as sleep,self.assertRaisesRegex(ValueError,'readback_pending'):
            task.settle(None,None,None,plan(),plan()['target'],plan()['baseline'],{},'advance',True)
        self.assertEqual(read.call_count,4);self.assertEqual(sleep.call_count,3)
    def test_unconfirmed_receipt_never_enters_wait_or_automatically_restores(self):
        with patch.object(task,'snapshot',return_value=False) as read,patch.object(task.time,'sleep') as sleep,self.assertRaises(ValueError):
            task.settle(None,None,None,plan(),plan()['target'],plan()['baseline'],{},'advance',False)
        read.assert_called_once();sleep.assert_not_called()
    def test_unknown_position_or_changed_counter_stops_at_first_observation(self):
        for error in ('txt_roundtrip/unknown_readback','native_txt/time_changed'):
            with patch.object(task,'snapshot',side_effect=ValueError(error)) as read,patch.object(task.time,'sleep') as sleep,self.assertRaises(ValueError):
                task.settle(None,None,None,plan(),plan()['target'],plan()['baseline'],{},'advance',True)
            read.assert_called_once();sleep.assert_not_called()
    def test_independent_transports_may_temporarily_show_different_whole_known_states(self):
        web,native,p,original=FreshStateTests().fixture();target=deepcopy(original)
        target['book'].update(chapterOffset=p['target']['chapter_offset'],summary=p['target']['summary'])
        native.request.side_effect=None;native.request.return_value=original;web.request.side_effect=[target,{'books':[]}]
        with patch.object(task,'state_hash',return_value=p['shelf_sha256']):
            self.assertFalse(task.snapshot(web,native,credentials(),p,p['target'],p['baseline']))
        native.request.return_value=target;web.request.side_effect=[target,{'books':[]}]
        with patch.object(task,'state_hash',return_value=p['shelf_sha256']):
            self.assertTrue(task.snapshot(web,native,credentials(),p,p['target'],p['baseline']))
    def test_partial_coordinate_and_summary_pair_is_not_a_known_state(self):
        web,native,p,partial=FreshStateTests().fixture();partial['book']['chapterOffset']=p['target']['chapter_offset']
        native.request.side_effect=None;native.request.return_value=partial;web.request.side_effect=[partial,{'books':[]}]
        with self.assertRaisesRegex(ValueError,'unknown_readback'):task.snapshot(web,native,credentials(),p,p['target'],p['baseline'])


if __name__=='__main__':unittest.main()
