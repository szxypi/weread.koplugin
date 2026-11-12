"""Distinct raw-summary source, one-shot recovery and cross-trial barriers."""
from contextlib import ExitStack,redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock,patch
from secure_weread_session import StoreError
from secure_raw_txt_excerpt import RawTxtExcerptStore
from secure_native_txt_roundtrip import NativeTxtRoundtripStore
from test_secure_native_session import Backend,credentials
from test_native_txt_roundtrip import fixture,plan as old_plan,RAW
from txt_coordinates import PlainSource
from native_txt_read_model import body
import verify_raw_txt_excerpt as task
import verify_native_txt_roundtrip as flow


def plan():
    value=old_plan();before,target=task.candidate(RAW,fixture())
    value.update(protocol=RawTxtExcerptStore.protocol,baseline=before,target=target);return value


class RawExcerptTests(unittest.TestCase):
    def test_raw_source_slice_does_not_copy_observed_summary_whitespace(self):
        p=plan();target=p['target']
        self.assertEqual(target['summary'],PlainSource(RAW).excerpt(target['chapter_offset'])['text'])
        self.assertIn('\r\n\u3000\u3000',target['summary'])
        self.assertNotEqual(target['summary'],old_plan()['target']['summary'])
        self.assertEqual(p['baseline'],old_plan()['baseline'])

    def test_wrong_basis_ambiguous_source_missing_or_wrong_target_rejected(self):
        for mutate in (lambda p:p.update(basis='filtered_xhtml_utf16'),lambda p:p.update(summary_unique_start_matches=False),
                       lambda p:p.update(target=None),lambda p:p['target'].update(chapter_offset=999)):
            value=fixture();mutate(value)
            with self.assertRaises(ValueError):task.candidate(RAW,value)

    def test_body_retains_all_raw_newlines_and_zero_time_fields(self):
        p=plan();value=body(credentials(),p['target'],0,'synthetic-guest',1700000000,123,'+08:00')
        self.assertEqual(value['summary'],p['target']['summary']);self.assertEqual(value['hours'],[])
        self.assertEqual(value['readingTime'],0);self.assertEqual(value['autoTime'],0)

    def test_storage_has_distinct_protocol_and_does_not_relax_old_window_rule(self):
        p=plan();store=RawTxtExcerptStore(Backend());store.reserve(p)
        self.assertNotEqual(store.service,NativeTxtRoundtripStore(Backend()).service)
        with self.assertRaises(StoreError):NativeTxtRoundtripStore(store.backend).read()
        old=deepcopy(p);old['protocol']=NativeTxtRoundtripStore.protocol
        with self.assertRaises(StoreError):NativeTxtRoundtripStore(Backend()).reserve(old)
        for mutate in (lambda p:p.update(protocol=NativeTxtRoundtripStore.protocol),lambda p:p['target'].update(summary='short'),
                       lambda p:p['target'].update(chapter_idx=99),lambda p:p.update(version=True),lambda p:p['counts'].update(ttsTime=True)):
            value=plan();mutate(value)
            with self.assertRaises(StoreError):RawTxtExcerptStore(Backend()).reserve(value)

    def test_pending_reopens_with_complete_original_and_no_reclaim(self):
        backend=Backend();store=RawTxtExcerptStore(backend);r=store.reserve(plan());r=store.advance(r,'prepared','advance_pending')
        value,_r=RawTxtExcerptStore(backend).read();self.assertEqual(value['plan']['baseline'],plan()['baseline'])
        with self.assertRaises(StoreError):store.reserve(plan())
        with self.assertRaises(StoreError):store.advance(r,'advance_pending','retired')

    def execute(self,acks=None,fail_readback=False):
        web=Mock();web.book_id='41';web.vid='900000';session=Mock();session.load.return_value={'vid':'900000'}
        native=flow.Probe(credentials(),'41');store=RawTxtExcerptStore(Backend());report={};events=[]
        responses=iter(acks or [{'succ':1},{'succ':1}])
        def send(*a,**kw):
            events.append(store.read()[0]['phase']);reply=next(responses)
            if isinstance(reply,Exception):raise reply
            return reply
        def settle(*a):
            if fail_readback:raise ValueError('txt_roundtrip/unknown_readback')
        with patch.object(flow,'check'),patch.object(flow,'settle',side_effect=settle),patch.object(flow,'save_refreshed_web_session'),\
             patch.object(flow,'NativeSessionStore') as native_store,patch('verify_eink_login.NativeProbe.request',side_effect=send):
            native_store.return_value.load.return_value=credentials()
            try:flow.run(web,native,credentials(),session,{},store,report,apply=True,planner=lambda *a:(plan(),'synthetic-guest'),summary_method='literal_raw_30')
            except Exception:report['stopped']=True
        return store,native,report,events

    def test_exactly_two_claimed_slots_and_full_restore_retire(self):
        store,native,report,events=self.execute()
        self.assertEqual(events,['advance_pending','restore_pending']);self.assertEqual(native.posts,2)
        self.assertEqual(store.read()[0]['phase'],'retired');self.assertEqual(report['summary_method'],'literal_raw_30')

    def test_unknown_or_transport_failure_never_restores_or_replays(self):
        for ack in ({},ValueError('synthetic failure')):
            store,native,r,events=self.execute([ack]);self.assertTrue(r['stopped'])
            self.assertEqual(native.posts,1);self.assertEqual(store.read()[0]['phase'],'advance_pending')
            self.assertEqual(events,['advance_pending'])

    def test_explicit_ack_persists_before_readback_failure(self):
        store,native,r,_events=self.execute(fail_readback=True)
        self.assertTrue(r['stopped']);self.assertEqual(native.posts,1);self.assertEqual(store.read()[0]['phase'],'advance_acknowledged')

    def test_shared_barrier_cannot_be_bypassed_by_old_exclusions(self):
        import verify_native_thought_trial as shared
        names=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore','NativeShelfTrialStore',
               'NativeFinishTrialStore','FlagTrialStore','NativeFlagTrialStore','TxtFullSummaryStore','TxtZeroTimeStore','NativeTxtPositionStore',
               'NativeTxtRoundtripStore','RawTxtExcerptStore','NativeReaderTrialStore','NativeCloseTrialStore','NativeTimerTrialStore','NativeInitialPositionStore','NativeInitialReaderStore','InitialMarkStyleStore','NonemptyMarksStore','ReadtimeTrialStore',
               'MarkColorStore','MarkStyleTrialStore','BookmarkTrialStore','HighlightTrialStore')
        with ExitStack() as context:
            factories={name:context.enter_context(patch.object(shared,name)) for name in names}
            for factory in factories.values():
                factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None)
            factories['RawTxtExcerptStore'].return_value.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_native_txt_roundtrip=True,exclude_native_txt_flow=True))
            self.assertFalse(shared.other_pending(exclude_raw_txt_excerpt=True))
            factories['NativeTxtRoundtripStore'].return_value.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_raw_txt_excerpt=True))

    def test_default_is_offline_and_private_errors_are_hidden(self):
        with patch.object(task,'SessionStore') as session,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)
        with patch('verify_native_thought_trial.other_pending',return_value=False),patch.object(task,'RawTxtExcerptStore') as store,\
             patch.object(task,'SessionStore',side_effect=ValueError('PRIVATE_COOKIE')),redirect_stdout(io.StringIO()) as out:
            store.return_value.read.return_value=(None,None);self.assertEqual(task.main(['--saved-session']),1)
        self.assertNotIn('PRIVATE_COOKIE',out.getvalue())


if __name__=='__main__':unittest.main()
