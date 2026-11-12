"""Offline lifecycle, original-record preservation, and no-repeat dispatch."""
from copy import deepcopy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import Mock,patch
from annotation_experiment_model import digest
from highlight_trial_model import bind,observe,PendingObservation,validate_plan
from secure_highlight_trial import HighlightTrialStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_selection_trial import fixture
from verify_eink_login import ProbeError
from verify_highlight_trial import HighlightProbe,main


def state(plan,body,*,added=True):
    value=deepcopy(plan.baseline)
    if added:value['marks']['updated']['new-highlight']=dict(bookmarkId='new-highlight',chapterUid=body['chapterUid'],
        type=1,style=1,colorStyle=0,range=body['range'],markText=body['markText'],createTime=1794400000)
    return value


class HighlightTests(unittest.TestCase):
    def setup_probe(self):
        _payload,plan=fixture();source=Mock();source.plan=plan
        source.prepare.return_value=plan;source.baseline.return_value=plan.baseline
        source.web.request.return_value={'bookId':'41','chapterUid':2,'chapterOffset':12,'progress':30}
        store=HighlightTrialStore(Backend());p=HighlightProbe(source,store,sleep=lambda _s:None)
        p.prepare({},{});return p,source,store,plan

    def test_request_has_only_source_fields_no_guessed_native_index(self):
        p,_source,_store,plan=self.setup_probe()
        self.assertEqual(set(p.body),{'bookId','chapterUid','bookVersion','type','style','colorStyle','range','markText'})
        self.assertEqual(p.body['chapterUid'],int(plan.context['chapterUid']))
        self.assertEqual(p.body['markText'],plan.context['abstract'])

    def test_distinct_protocol_and_strict_shape(self):
        p,_s,_store,_plan=self.setup_probe();bad=deepcopy(p.bound);bad['protocol']='native-fresh-selection-three-notes-optional-new-mark-cleanup-v1'
        with self.assertRaises(ValueError):validate_plan(bad)
        with self.assertRaises(ValueError):validate_plan(dict(p.bound,extra=True))

    def test_exact_new_mark_and_removal(self):
        p,_s,_store,plan=self.setup_probe();added=state(plan,p.body);target=observe(plan.baseline,added,p.body)
        self.assertEqual(target,dict(id='new-highlight',sha256=digest(added['marks']['updated']['new-highlight'])))
        self.assertIsNone(observe(plan.baseline,plan.baseline,p.body,deleted=True,target=target))
        with self.assertRaises(PendingObservation):observe(plan.baseline,plan.baseline,p.body)
        with self.assertRaises(PendingObservation):observe(plan.baseline,added,p.body,deleted=True,target=target)

    def test_every_original_collection_is_protected(self):
        p,_s,_store,plan=self.setup_probe()
        for key in ('shelf','position','thoughts'):
            current=state(plan,p.body);current[key]['unrelated']=True
            with self.subTest(key=key),self.assertRaises(ValueError):observe(plan.baseline,current,p.body)
        for group in ('updated','chapters'):
            current=state(plan,p.body);current['marks'][group]['unrelated']={}
            with self.subTest(group=group),self.assertRaises(ValueError):observe(plan.baseline,current,p.body)
        for name,row in plan.baseline['marks']['updated'].items():
            current=state(plan,p.body);del current['marks']['updated'][name]
            with self.assertRaises(ValueError):observe(plan.baseline,current,p.body)

    def test_one_selected_chapter_descriptor_may_persist_but_others_cannot(self):
        p,_s,_store,plan=self.setup_probe();current=state(plan,p.body)
        current['marks']['chapters'][str(p.body['chapterUid'])]='Synthetic chapter'
        self.assertIsNotNone(observe(plan.baseline,current,p.body))
        current['marks']['chapters']['999']='Other chapter'
        with self.assertRaises(ValueError):observe(plan.baseline,current,p.body)

    def test_each_row_field_must_match_and_target_fingerprint_must_stay(self):
        p,_s,_store,plan=self.setup_probe();current=state(plan,p.body);target=observe(plan.baseline,current,p.body)
        for k in ('chapterUid','type','style','colorStyle','range','markText','bookmarkId'):
            bad=deepcopy(current);bad['marks']['updated']['new-highlight'][k]=False
            with self.subTest(k=k),self.assertRaises(ValueError):observe(plan.baseline,bad,p.body)
        current['marks']['updated']['new-highlight']['createTime']+=1
        with self.assertRaises(ValueError):observe(plan.baseline,current,p.body,target=target)

    def test_no_replay_after_reservation_even_before_first_post(self):
        p,_s,store,_plan=self.setup_probe();r=store.reserve(p.bound)
        self.assertEqual(store.read()[0]['reserved_posts'],2)
        for action in (lambda:store.reserve(p.bound),lambda:store.finish(r),lambda:store.advance(r,'delete_pending')):
            with self.assertRaises(StoreError):action()
        reopened=HighlightTrialStore(store.backend)
        with self.assertRaises(StoreError):reopened.reserve(p.bound)

    def test_store_cas_single_use_and_no_invalid_target_write(self):
        p,_s,store,_plan=self.setup_probe();r=store.reserve(p.bound);before=store.backend.load()
        with self.assertRaises(StoreError):store.advance(r,'created',target={'id':'x'})
        self.assertEqual(store.backend.load(),before)
        r2=store.advance(r,'created',target=dict(id='new-highlight',sha256='a'*64))
        with self.assertRaises(StoreError):store.advance(r,'created',target=dict(id='new-highlight',sha256='a'*64))
        r3=store.advance(r2,'delete_pending');r4=store.advance(r3,'verified');store.finish(r4)
        self.assertEqual(store.read(),(None,None))

    def test_only_exact_body_and_only_one_dispatch_per_phase(self):
        p,source,store,_plan=self.setup_probe();p.receipt=store.reserve(p.bound)
        with self.assertRaises(ValueError):p.post({},'create_pending','/book/addBookmark',dict(p.body,chapterIdx=2))
        p.post({},'create_pending','/book/addBookmark',p.body)
        with self.assertRaises(ValueError):p.post({},'create_pending','/book/addBookmark',p.body)
        self.assertEqual(source.writer.request.call_count,1)
        p.target=dict(id='new-highlight',sha256='a'*64)
        p.receipt=store.advance(p.receipt,'created',target=p.target);p.receipt=store.advance(p.receipt,'delete_pending')
        p.target=dict(id='old-mark',sha256='a'*64)
        with self.assertRaises(ValueError):p.post({},'delete_pending','/book/removeBookmark',dict(bookmarkIds=['old-mark']))
        self.assertEqual(source.writer.request.call_count,1)

    def test_unknown_receipt_is_never_retried(self):
        p,source,store,_plan=self.setup_probe();source.writer.request.side_effect=ProbeError('lost')
        p.receipt=store.reserve(p.bound);p.post({},'create_pending','/book/addBookmark',p.body)
        with self.assertRaises(ValueError):p.post({},'create_pending','/book/addBookmark',p.body)
        self.assertEqual(source.writer.request.call_count,1)

    def test_readback_retries_are_only_reads_and_original_changes_stop_immediately(self):
        p,source,_store,plan=self.setup_probe();current=state(plan,p.body)
        source.notes.observe.side_effect=[plan.baseline,current]
        self.assertEqual(p.read({})[0]['id'],'new-highlight')
        self.assertFalse(source.writer.request.called)
        current['thoughts']['unexpected']={};source.notes.observe.side_effect=[current]
        with self.assertRaises(ValueError):p.read({})

    def test_changed_body_cannot_be_rebound_to_bypass_source(self):
        p,_s,_store,_plan=self.setup_probe();p.body['range']='900-901';p.bound=bind(p.source.plan.bound,p.body)
        with self.assertRaises(ValueError):p.current()

    def test_full_two_write_lifecycle_and_independent_final_position(self):
        p,source,store,plan=self.setup_probe();added=state(plan,p.body)
        source.notes.observe.side_effect=[added,added,plan.baseline]
        with patch('verify_highlight_trial.reading_position',return_value=plan.web_position):result=p.run({},apply=True)
        self.assertEqual(result['account_data_posts'],2)
        self.assertTrue(result['original_state_unchanged']);self.assertEqual(store.read(),(None,None))
        calls=source.writer.request.call_args_list
        self.assertEqual(calls[0].args[2],p.body)
        self.assertEqual(calls[1].args[2],dict(bookmarkIds=['new-highlight']))
        self.assertEqual(source.notes.observe.call_count,3)

    def test_readonly_has_no_intent_no_writes_and_uses_allowed_web_stage(self):
        p,source,store,plan=self.setup_probe()
        with patch('verify_highlight_trial.reading_position',return_value=plan.web_position):result=p.run({})
        self.assertEqual(result['account_data_posts'],0);self.assertEqual(store.read(),(None,None))
        self.assertFalse(source.writer.request.called);self.assertEqual(source.web.request.call_args.args[0],'progress_after')

    def test_failed_create_readback_stops_without_deletion_and_pending_cannot_restart(self):
        p,source,store,plan=self.setup_probe();source.notes.observe.return_value=plan.baseline
        with self.assertRaises(PendingObservation):p.run({},apply=True)
        self.assertEqual(source.writer.request.call_count,1)
        self.assertEqual(store.read()[0]['phase'],'create_pending')
        with self.assertRaises(ValueError):HighlightProbe(source,store).prepare({},{})

    def test_changed_original_before_delete_stops_with_new_record_pending(self):
        p,source,store,plan=self.setup_probe();added=state(plan,p.body);changed=deepcopy(added)
        changed['shelf']['unexpected']=True;source.notes.observe.side_effect=[added,changed]
        with self.assertRaises(ValueError):p.run({},apply=True)
        self.assertEqual(p.posts,1);self.assertEqual(store.read()[0]['phase'],'created')

    def test_final_web_position_mismatch_does_not_claim_full_restoration(self):
        p,source,store,plan=self.setup_probe();added=state(plan,p.body)
        source.notes.observe.side_effect=[added,added,plan.baseline]
        with patch('verify_highlight_trial.reading_position',return_value={}):
            with self.assertRaises(ValueError):p.run({},apply=True)
        self.assertEqual(p.posts,2);self.assertEqual(store.read()[0]['phase'],'delete_pending')

    def test_offline_default_and_apply_without_session_do_not_open_credentials(self):
        for args,expected in (([],0),(['--apply'],1)):
            with patch('verify_highlight_trial.SessionStore') as login,patch('verify_highlight_trial.HighlightProbe') as probe,redirect_stdout(io.StringIO()) as output:
                self.assertEqual(main(args),expected)
            self.assertFalse(login.called);self.assertFalse(probe.called)
            self.assertEqual(json.loads(output.getvalue())['account_data_posts'],0)

    def test_status_reads_only_intent_without_loading_login_or_network(self):
        with patch('verify_highlight_trial.HighlightTrialStore') as factory,patch('verify_highlight_trial.SessionStore') as login,patch('verify_highlight_trial.HighlightProbe') as probe,redirect_stdout(io.StringIO()) as output:
            factory.return_value.read.return_value=(None,None)
            self.assertEqual(main(['--saved-session','--status']),0)
        self.assertFalse(login.called);self.assertFalse(probe.called)
        self.assertEqual(json.loads(output.getvalue())['intent_state'],'absent')

    def test_failed_durable_reservation_never_reaches_transport(self):
        p,source,store,_plan=self.setup_probe();store.backend.save=lambda _raw:None
        with self.assertRaises(StoreError):p.run({},apply=True)
        self.assertEqual(p.posts,0);self.assertFalse(source.writer.request.called)


if __name__=='__main__':unittest.main()
