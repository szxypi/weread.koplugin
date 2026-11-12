"""ReaderUI trial binding, persistent slots and independent broker failures."""
from contextlib import ExitStack,redirect_stdout,redirect_stderr
from copy import deepcopy
import io
import json
import time
import unittest
from unittest.mock import Mock,patch
from native_reader_fixture import GRANT
from secure_weread_session import StoreError
from secure_native_close_trial import NativeCloseTrialStore
from secure_raw_txt_excerpt import RawTxtExcerptStore
from secure_native_reader_trial import NativeReaderTrialStore
from secure_native_txt_roundtrip import NativeTxtRoundtripStore
from test_secure_native_session import Backend
from test_raw_txt_excerpt import plan as raw_plan
from test_owner_reading import stage as reading_stage
from native_txt_read_model import body
from txt_full_summary import digest
from native_close_trial_contract import FLAGS,validate_payload,validate_stage,validate_result
import native_close_trial_broker as broker
import verify_native_close_trial as task


def plan():
    p=raw_plan();p.update(protocol=NativeCloseTrialStore.protocol,grant_sha256=digest(GRANT))
    for key in ('baseline','target'):p[key].update(book_id='900001',chapter_idx=2)
    p['target']['raw_percent']=23;return p


def payload(armed=True,prepare=False):
    p=plan()
    if prepare:p['target']['raw_percent']=12
    return dict(book_id='900001',chapter_uid='2',source_text='Synthetic source for reader validation only.',shelf_ids=['900001'],shelf_books=1,
                source_format='web_txt',source_raw_sha256=p['source_sha256'],source_sample_offset=8,vid=GRANT['vid'],
                cookies=dict(wr_vid=GRANT['vid'],wr_skey='mock_key'),native_source_excerpt=True,native_grant=deepcopy(GRANT),reader_mock_port=12345,
                native_close_trial=dict(plan=p,armed=armed,bind_percent=not prepare,rpc_token='a'*32,native_shelf_sha256='c'*64,guest='5ecdcfd7f',time_zone='+08:00'))


def result(armed):
    stage=reading_stage();a={key:True for key in FLAGS};a.update(phase='complete',permit_writes=armed,restore_source=armed,
                               local_commit=armed,dispatch_blocked=not armed,native_gets=15 if armed else 7,native_posts=2 if armed else 0,
                               blocked_posts=0 if armed else 1,native_denied=0,last_native_status=200,acknowledged=2 if armed else 0,
                               steps=2 if armed else 0,failed_line=0)
    stage['native_close_trial']=a
    return dict(result='PASS',profile_removed=True,installed=dict(files=279,bytes_match=True),stage=stage,cookies=dict(wr_vid='900000',wr_skey='mock_key'))


def events(value):
    t=value['native_close_trial'];p=plan();metadata=dict(book_id='900001',before=deepcopy(p['baseline']),desired=deepcopy(p['target']),
        counts=deepcopy(p['counts']),version=p['version'],shelf_sha256=t['native_shelf_sha256'],source_sha256=p['source_sha256'],file_id='a'*64,basis='raw_txt_utf16')
    items=[('STEP',dict(kind='plan',seq=1,metadata=metadata,reader_percent=23))]
    for seq in (1,2) if t['armed'] else (1,):
        dto=body(GRANT,p['target' if seq==1 else 'baseline'],p['version'],t['guest'],int(time.time()),123,t['time_zone'])
        items.append(('STEP',dict(kind='claim' if t['armed'] else 'dry_body',seq=seq,body=dto)))
        if t['armed']:items.extend([('STEP',dict(kind='ack',seq=seq)),('STEP',dict(kind='verified',seq=seq))])
    return items+[('RESULT',result(t['armed']))]


class Child:
    def __init__(self):self.stdin=io.BytesIO();self.stdout=io.BytesIO()
    def wait(self,timeout=None):return 0
    def poll(self):return None


class CloseTrialTests(unittest.TestCase):
    def run_case(self,*,armed=True,prepare=False,modify=None,after=None):
        value=payload(armed,prepare);store=NativeCloseTrialStore(Backend())
        if not prepare:store.reserve(value['native_close_trial']['plan'])
        frames=Mock();sequence=events(value)
        if modify:modify(sequence)
        frames.next.side_effect=sequence;report={};replies=[];child=Child()
        def answer(_stream,reply):
            if reply['ok'] and armed and reply['kind']=='claim':
                self.assertEqual(store.read()[0]['phase'],'advance_pending' if reply['seq']==1 else 'restore_pending')
            replies.append(reply)
        with patch.object(broker.subprocess,'Popen',return_value=child),patch.object(broker,'Frames',return_value=frames),\
             patch.object(broker,'reply',side_effect=answer),patch.object(broker,'stop') as stop:
            try:broker.execute(value,['synthetic-command'],store,report,prepare=prepare,after=after)
            except Exception:report['stopped']=True
        stop.assert_called_once_with(child);return value,store,report,replies

    def test_prepare_binds_observed_reader_percent_without_a_claim(self):
        value,store,r,replies=self.run_case(armed=False,prepare=True)
        self.assertEqual(store.read()[0]['phase'],'prepared');self.assertEqual(store.read()[0]['posts'],0)
        self.assertEqual(store.read()[0]['plan']['target']['raw_percent'],23);self.assertEqual(r['synthetic_posts'],0)
        self.assertEqual(value['native_close_trial']['plan']['target']['raw_percent'],23);self.assertEqual(len(replies),2)
    def test_disarmed_repeat_preserves_the_prepared_scope(self):
        _value,store,r,_replies=self.run_case(armed=False)
        self.assertEqual(store.read()[0]['phase'],'prepared');self.assertEqual(r['result'],'NATIVE_CLOSE_TRIAL_DISARMED_VERIFIED')
    def test_two_durable_claims_acknowledged_and_independently_verified(self):
        _value,store,r,replies=self.run_case()
        self.assertEqual(store.read()[0]['phase'],'retired');self.assertEqual(r['synthetic_posts'],2)
        self.assertEqual(r['account_data_posts'],0);self.assertEqual(r['independent_steps'],2);self.assertEqual(len(replies),7)
        with self.assertRaises(StoreError):store.reserve(plan())
    def test_new_protocol_does_not_relax_or_reuse_old_trials(self):
        backend=Backend();store=NativeCloseTrialStore(backend);store.reserve(plan())
        self.assertNotEqual(store.service,RawTxtExcerptStore(Backend()).service)
        for old in (RawTxtExcerptStore(backend),NativeTxtRoundtripStore(backend,native=True),NativeReaderTrialStore(backend)):
            with self.assertRaises(StoreError):old.read()
        with self.assertRaises(TypeError):NativeCloseTrialStore(Backend(),native=True)
    def test_only_integral_reader_percentage_can_change_in_new_plan(self):
        for changes in ({'chapter_idx':3},{'raw_percent':1.5},{'raw_percent':True},{'summary':'short'},{'chapter_offset':999}):
            p=plan();p['target'].update(changes)
            with self.subTest(changes=changes),self.assertRaises(StoreError):NativeCloseTrialStore(Backend()).reserve(p)
    def test_actual_reader_plan_cannot_change_the_frozen_percentage_or_counts(self):
        for change in ('percent','counts','source','before','fields'):
            def mutate(items):
                m=items[0][1]['metadata']
                if change=='percent':m['desired']['raw_percent']=24;items[0][1]['reader_percent']=24
                elif change=='counts':m['counts']['readingTime']+=1
                elif change=='source':m['source_sha256']='f'*64
                elif change=='before':m['before']['summary']='changed original'
                else:m['extra']='private'
            _v,store,r,_a=self.run_case(modify=mutate)
            self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['posts'],0)
    def test_invalid_signature_summary_hours_clock_never_claims(self):
        for change in ({'signature':'0'*64},{'summary':'changed'},{'hours':{}},{'timestamp':int(time.time())-31},{'readingTime':False}):
            _v,store,r,_a=self.run_case(modify=lambda items:items[1][1]['body'].update(change))
            self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'prepared')
    def test_duplicate_claim_and_verified_without_ack_never_advance(self):
        for modify in (lambda items:items.insert(2,deepcopy(items[1])),lambda items:items.pop(2)):
            _v,store,r,_a=self.run_case(modify=modify);self.assertTrue(r['stopped'])
            self.assertEqual(store.read()[0]['phase'],'advance_pending')
    def test_ack_survives_independent_read_failure_without_restoring(self):
        _v,store,r,replies=self.run_case(after=Mock(side_effect=ValueError('close_trial/source_changed')))
        self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'advance_acknowledged')
        self.assertEqual(r['synthetic_posts'],1);self.assertEqual(r['explicit_success_receipts'],1)
        self.assertFalse(replies[-1]['ok'])
    def test_interruption_after_claim_keeps_unknown_slot_and_never_restores(self):
        def truncate(items):del items[2:]
        _v,store,r,replies=self.run_case(modify=truncate)
        self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'advance_pending')
        self.assertEqual(r['synthetic_posts'],1);self.assertEqual(r['explicit_success_receipts'],0)
        self.assertEqual([v['kind'] for v in replies if v['ok']],['plan','claim'])
    def test_missing_profile_cleanup_and_wrong_runner_mode_are_rejected(self):
        for key,bad in (('profile_removed',False),('installed',dict(files=279,bytes_match=False))):
            value=result(True);value[key]=bad
            with self.assertRaises(ValueError):validate_result(value,True,GRANT['vid'])
        value=result(True);value['stage']['native_close_trial']['permit_writes']=False
        with self.assertRaises(ValueError):validate_stage(value['stage'],True)
    def test_closed_document_proofs_are_individually_required(self):
        for key in ('baseline_readonly','document_closed','no_closed_document_calls','archive_worker'):
            value=result(True);value['stage']['native_close_trial'][key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(value['stage'],True)
        value=result(True);value['stage']['native_close_trial']['manual_controls']=True
        with self.assertRaises(ValueError):validate_stage(value['stage'],True)
    def test_payload_scope_mock_cookie_and_private_extras_are_closed(self):
        for mutate in (lambda v:v.update(extra='private'),lambda v:v.update(book_id='41'),
                       lambda v:v['native_grant'].update(accessToken='real-other-token'),lambda v:v['native_close_trial'].update(armed=1)):
            value=payload();mutate(value)
            with self.assertRaises((ValueError,StoreError)):validate_payload(value,True,12345)
        with self.assertRaises(ValueError):validate_payload(payload(),True,None)
    def test_global_barrier_requires_its_own_exclusion_only(self):
        import verify_native_thought_trial as shared
        names=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore','NativeShelfTrialStore',
               'NativeFinishTrialStore','FlagTrialStore','NativeFlagTrialStore','TxtFullSummaryStore','TxtZeroTimeStore','NativeTxtPositionStore',
               'NativeTxtRoundtripStore','RawTxtExcerptStore','NativeReaderTrialStore','NativeCloseTrialStore','NativeTimerTrialStore','InitialMarkStyleStore','NonemptyMarksStore',
               'ReadtimeTrialStore','MarkColorStore','MarkStyleTrialStore','BookmarkTrialStore','HighlightTrialStore')
        with ExitStack() as context:
            factories={name:context.enter_context(patch.object(shared,name)) for name in names}
            for factory in factories.values():factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None)
            factories['NativeCloseTrialStore'].return_value.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_native_txt_flow=True,exclude_raw_txt_excerpt=True,exclude_native_reader_trial=True))
            self.assertFalse(shared.other_pending(exclude_native_close_trial=True))
            factories['RawTxtExcerptStore'].return_value.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_native_close_trial=True))
    def test_default_never_accesses_credentials_or_starts_a_child(self):
        with patch.object(task,'SessionStore') as session,patch.object(broker.subprocess,'Popen') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();child.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_incomplete_cli_and_private_errors_do_not_escape(self):
        for args in (['--saved-session'],['--prepare'],['--native-ui-command','synthetic']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)
        with patch('verify_native_thought_trial.other_pending',return_value=False),\
             patch.object(task,'SessionStore',side_effect=ValueError('PRIVATE_COOKIE')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main(['--saved-session','--prepare','--native-ui-command','synthetic']),1)
        self.assertNotIn('PRIVATE_COOKIE',out.getvalue());self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)


if __name__=='__main__':unittest.main()
