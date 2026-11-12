"""Synthetic full-summary signing, one-shot claims and independent barriers."""
from contextlib import redirect_stdout,ExitStack
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock,patch
from test_secure_native_session import Backend
from test_txt_cloud_position import RAW,fixture
from txt_cloud_position import prepare as source_plan
import txt_full_summary as model
from secure_txt_full_summary import TxtFullSummaryStore,StoreError
import verify_txt_full_summary as task


def plan():
    progress,ctx,chapters=fixture();at=RAW.index('独立');progress['book']['summary']=RAW[at:at+30];ctx['progress']=deepcopy(progress)
    return source_plan(RAW,progress,ctx,chapters,'41')


def bound():return dict(protocol=model.PROTOCOL,**{k:'a'*64 for k in model.HASHES})


class Fake(task.Probe):
    def __init__(self,ack=None):
        super().__init__();self.vid='900000';self.authenticated=True;self.set_cookie('wr_vid','900000');self.book_id='41'
        self.sample=dict(plain=RAW);self.reads=0;self.acks=ack or [dict(succ=1),dict(succ=1)];self.sent=[];self.break_read=None
    def find_sample(self,limit):assert limit==16;return True
    def inspect_plan(self):return plan()
    def verify_account(self):pass
    def exact(self,baseline,shelf_hash):
        self.reads+=1
        if self.reads==self.break_read:raise ValueError('concurrent change')
    def request(self,stage,url,body=None,**options):
        if stage=='shelf':return dict(books=[dict(bookId='41',secret=0,finishReading=0)])
        self.guard(stage,url,body);self.sent.append(deepcopy(body))
        response=self.acks.pop(0)
        if isinstance(response,Exception):raise response
        return response


class FullSummaryTests(unittest.TestCase):
    def test_full_string_is_preserved_and_resigned_for_both_stages(self):
        p=model.prepare(plan())
        for stage in ('write_enter','write_same'):
            value=model.payload(p,stage);self.assertEqual(len(value['sm']),30);self.assertEqual(value['sm'],plan()['baseline']['summary'])
            self.assertTrue(task.validate_payload(p,stage,value))
            self.assertEqual('rt' in value,stage=='write_same')
            if stage=='write_same':self.assertEqual(value['rt'],0)
    def test_malformed_or_unbound_summary_is_rejected(self):
        for kind in ('basis','long','null','unmatched'):
            p=plan()
            if kind=='basis':p['basis']='filtered_xhtml_utf16'
            elif kind=='long':p['baseline']['summary']='x'*513
            elif kind=='null':p['baseline']['summary']='bad\0'
            else:p['summary_unique_start_matches']=False
            with self.subTest(kind=kind),self.assertRaises(ValueError):model.prepare(p)
    def test_other_stages_and_tampered_payload_cannot_dispatch(self):
        web=Fake();web.wire=model.prepare(plan());value=model.payload(web.wire,'write_enter');value['co']+=1
        claim=Mock()
        with self.assertRaises(ValueError):web.send('write_enter',value,claim)
        claim.assert_not_called();self.assertEqual(web.posts,0)
        with self.assertRaises(ValueError):model.payload(web.wire,'write_restore')
    def test_intent_claims_are_cas_and_tombstone_blocks_replay(self):
        backend=Backend();store=TxtFullSummaryStore(backend);receipt=store.reserve(bound())
        for before,after in (('prepared','enter_pending'),('enter_pending','enter_verified'),('enter_verified','same_pending'),('same_pending','retired')):
            old=receipt;receipt=store.advance(receipt,before,after)
            with self.assertRaises(StoreError):store.advance(old,before,after)
        self.assertFalse(TxtFullSummaryStore(backend).pending());self.assertEqual(store.read()[0]['posts'],2)
        with self.assertRaises(StoreError):store.reserve(bound())
    def test_failed_readback_or_corruption_never_allows_a_new_reservation(self):
        backend=Backend();store=TxtFullSummaryStore(backend);store.reserve(bound());backend.data=b'{}'
        with self.assertRaises(StoreError):store.pending()
        backend=Backend();backend.load=lambda:None
        with self.assertRaises(StoreError):TxtFullSummaryStore(backend).reserve(bound())
    def test_unsent_abort_is_terminal_but_claimed_write_cannot_be_aborted(self):
        store=TxtFullSummaryStore(Backend());r=store.reserve(bound());r=store.advance(r,'prepared','enter_pending')
        with self.assertRaises(StoreError):store.advance(r,'prepared','aborted')
        self.assertTrue(store.pending())
        store=TxtFullSummaryStore(Backend());r=store.reserve(bound());store.advance(r,'prepared','aborted');self.assertFalse(store.pending())
        with self.assertRaises(StoreError):store.reserve(bound())
    def execute(self,web,apply=True):
        session=Mock();saved=dict(vid='900000',cookies={});session.load.side_effect=lambda:deepcopy(saved)
        store=TxtFullSummaryStore(Backend());report={}
        with patch.object(task,'save_refreshed_web_session',return_value=False):
            try:task.run(web,session,saved,store,report,apply)
            except Exception:report['stopped']=True
        return store,report
    def test_success_requires_two_claims_and_independent_reads(self):
        web=Fake();store,report=self.execute(web)
        self.assertEqual(report['result'],'TXT_FULL_SUMMARY_SAME_POINT_VERIFIED');self.assertEqual(web.posts,2)
        self.assertEqual(web.reads,6);self.assertFalse(store.pending());self.assertEqual(store.read()[0]['phase'],'retired')
        self.assertEqual(web.sent[0]['sm'],web.sent[1]['sm'])
    def test_no_apply_reserves_nothing_and_sends_nothing(self):
        web=Fake();store,report=self.execute(web,False);self.assertEqual(web.posts,0);self.assertEqual(store.read(),(None,None))
        self.assertEqual(report['result'],'FULL_SUMMARY_SAME_POINT_PLAN_VERIFIED')
    def test_unknown_ack_stops_after_readback_and_does_not_send_next_stage(self):
        for ack in ({},{'succ':0}):
            web=Fake([ack]);store,report=self.execute(web)
            self.assertTrue(report['stopped']);self.assertEqual(web.posts,1);self.assertEqual(web.reads,3);self.assertTrue(store.pending())
    def test_lost_response_stops_without_replay(self):
        web=Fake([ValueError('synthetic timeout')]);store,report=self.execute(web)
        self.assertTrue(report['stopped']);self.assertEqual(web.posts,1);self.assertEqual(web.reads,3);self.assertTrue(store.pending())
    def test_concurrent_change_after_enter_stops_second_request(self):
        web=Fake();web.break_read=3;store,report=self.execute(web)
        self.assertTrue(report['stopped']);self.assertEqual(web.posts,1);self.assertTrue(store.pending())
    def test_claim_failure_never_reaches_transport(self):
        web=Fake();web.wire=model.prepare(plan());claim=Mock(side_effect=StoreError('readback'))
        with self.assertRaises(StoreError):web.send('write_enter',model.payload(web.wire,'write_enter'),claim)
        self.assertEqual((web.posts,len(web.sent)),(0,0))
    def test_offline_never_opens_credentials(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)
    def test_resolution_verifies_bindings_without_claiming_protocol_success(self):
        web=Fake();value=bound();value.update(owner_sha256=model.digest(web.vid),source_sha256=task.hashlib.sha256(RAW.encode()).hexdigest(),
            baseline_sha256=model.digest(model.prepare(plan())['baseline']))
        store=TxtFullSummaryStore(Backend());r=store.reserve(value);store.advance(r,'prepared','enter_pending');report={}
        task.resolve(web,store,report)
        self.assertFalse(report['prior_protocol_success_claimed']);self.assertEqual(store.read()[0]['phase'],'closed_enter_unverified')
        self.assertFalse(store.pending());self.assertEqual((web.posts,len(web.sent)),(0,0))
        with self.assertRaises(StoreError):store.reserve(value)
    def test_changed_source_or_owner_does_not_close_pending_result(self):
        for kind in ('owner','source','baseline','shelf'):
            web=Fake();value=bound();value.update(owner_sha256=model.digest(web.vid),source_sha256=task.hashlib.sha256(RAW.encode()).hexdigest(),
                baseline_sha256=model.digest(model.prepare(plan())['baseline']))
            store=TxtFullSummaryStore(Backend());r=store.reserve(value);store.advance(r,'prepared','enter_pending')
            if kind=='owner':web.vid='900099'
            elif kind=='source':web.sample['plain']+='changed'
            elif kind=='baseline':
                original=web.inspect_plan
                def changed():
                    v=original();v['baseline']['chapter_offset']+=1;return v
                web.inspect_plan=changed
            else:web.break_read=1
            with self.subTest(kind=kind),self.assertRaises(ValueError):task.resolve(web,store,{})
            self.assertTrue(store.pending());self.assertEqual(web.posts,0)
    def test_receipt_diagnostics_never_emit_unknown_strings_or_fields(self):
        result=model.receipt_summary(dict(status=1,succ='synthetic private response',other='synthetic private field'))
        self.assertEqual(result,dict(object=True,status_type='int',status_known_value='1',succ_type='str'))
        self.assertNotIn('synthetic',json.dumps(result))

    def test_shared_guard_cannot_bypass_pending_txt_intent(self):
        import verify_native_thought_trial as shared
        factories=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore','NativeShelfTrialStore',
            'NativeFinishTrialStore','FlagTrialStore','NativeFlagTrialStore','TxtFullSummaryStore','TxtZeroTimeStore','NativeTxtPositionStore','NativeTxtRoundtripStore','RawTxtExcerptStore','NativeReaderTrialStore','NativeCloseTrialStore','NativeTimerTrialStore','NativeInitialPositionStore','NativeInitialReaderStore','MarkStyleTrialStore','HighlightTrialStore',
            'BookmarkTrialStore','InitialMarkStyleStore','MarkColorStore','NonemptyMarksStore','ReadtimeTrialStore')
        with ExitStack() as stack:
            mocks={k:stack.enter_context(patch.object(shared,k)) for k in factories}
            for value in mocks.values():value.return_value.pending.return_value=False;value.return_value.read.return_value=(None,None)
            self.assertFalse(shared.other_pending());mocks['TxtFullSummaryStore'].return_value.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_native_finish=True,exclude_native_shelf=True,exclude_mark_color=True))
            self.assertFalse(shared.other_pending(exclude_txt_full_summary=True))
            mocks['NativeFinishTrialStore'].return_value.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_txt_full_summary=True))


if __name__=='__main__':unittest.main()
