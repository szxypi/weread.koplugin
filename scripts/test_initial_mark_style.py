"""Initial-style prototypes must preserve the complete two-write contract."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import Mock,patch
from initial_mark_style_model import create_body,validate_plan
from secure_initial_mark_style import InitialMarkStyleStore,SERVICE
from secure_highlight_trial import HighlightTrialStore,SERVICE as ORIGINAL_SERVICE
from secure_weread_session import StoreError
from test_highlight_trial import state
from test_secure_native_session import Backend
from test_selection_trial import fixture
from verify_eink_login import ProbeError
from verify_initial_mark_style import InitialStyleProbe,main


class InitialStyleTests(unittest.TestCase):
    def probe(self,style):
        _payload,plan=fixture();source=Mock();source.plan=plan
        source.prepare.return_value=plan;source.baseline.return_value=plan.baseline
        store=InitialMarkStyleStore(Backend());p=InitialStyleProbe(style,source,store,sleep=lambda _s:None);p.prepare({},{})
        added=state(plan,p.body);added['marks']['updated']['new-highlight']['style']=style
        return p,source,store,plan,added
    def test_only_initial_style_differs_from_original_fixed_marker_request(self):
        bodies=[self.probe(s)[0].body for s in (0,1,2)]
        for style,body in enumerate(bodies):
            self.assertEqual(body['style'],style);self.assertEqual(dict(body,style=1),bodies[1])
            self.assertNotIn('chapterIdx',body);self.assertEqual(body['colorStyle'],0)
    def test_invalid_styles_fail_before_source_or_storage_access(self):
        for style in (True,False,-1,3,'2',None,1.5):
            with self.subTest(style=style),patch('verify_initial_mark_style.InitialMarkStyleStore') as store,self.assertRaises(ValueError):InitialStyleProbe(style)
            store.assert_not_called()
    def test_each_style_has_a_distinct_bound_request_and_old_intent_is_incompatible(self):
        plans=[self.probe(s)[0].bound for s in (0,1,2)]
        self.assertEqual(len({p['highlight']['request_sha256'] for p in plans}),3)
        self.assertNotEqual(SERVICE,ORIGINAL_SERVICE)
        with self.assertRaises(ValueError):HighlightTrialStore(Backend()).reserve(plans[0])
        for invalid in (dict(plans[0],style=True),dict(plans[0],extra=1),plans[0]['highlight']):
            with self.assertRaises(ValueError):validate_plan(invalid)
    def test_exact_two_writes_for_each_style_then_intent_is_removed(self):
        for style in (0,1,2):
            p,source,store,plan,added=self.probe(style);source.notes.observe.side_effect=[added,added,plan.baseline]
            with self.subTest(style=style),patch('verify_highlight_trial.reading_position',return_value=plan.web_position):r=p.run({},apply=True)
            self.assertEqual(r['account_data_posts'],2);self.assertEqual(store.read(),(None,None))
            self.assertEqual(source.writer.request.call_args_list[0].args[2],p.body)
            self.assertEqual(source.writer.request.call_args_list[1].args[2],dict(bookmarkIds=['new-highlight']))
    def test_wrong_returned_style_never_triggers_deletion_or_replay(self):
        p,source,store,_plan,added=self.probe(0);added['marks']['updated']['new-highlight']['style']=1
        source.notes.observe.return_value=added
        with self.assertRaises(ValueError):p.run({},apply=True)
        self.assertEqual(p.posts,1);self.assertEqual(store.read()[0]['phase'],'create_pending')
        with self.assertRaises(ValueError):InitialStyleProbe(0,source,store).prepare({},{})
        self.assertEqual(source.writer.request.call_count,1)
    def test_changed_originals_stop_after_create(self):
        p,source,store,_plan,added=self.probe(2);added['position']['external']=1;source.notes.observe.return_value=added
        with self.assertRaises(ValueError):p.run({},apply=True)
        self.assertEqual(p.posts,1);self.assertEqual(store.read()[0]['phase'],'create_pending')
    def test_unknown_receipts_are_confirmed_only_by_reads(self):
        p,source,store,plan,added=self.probe(2);source.writer.request.side_effect=ProbeError('lost')
        source.notes.observe.side_effect=[added,added,plan.baseline]
        with patch('verify_highlight_trial.reading_position',return_value=plan.web_position):r=p.run({},apply=True)
        self.assertEqual(r['account_data_posts'],2);self.assertEqual(source.writer.request.call_count,2);self.assertEqual(store.read(),(None,None))
    def test_body_tampering_cannot_rebind_source_range_or_initial_style(self):
        p,_source,_store,plan,_added=self.probe(0);p.body['range']='900-901'
        with self.assertRaises(ValueError):p.current()
        p.body=create_body(plan.context,2)
        with self.assertRaises(ValueError):p.current()
    def test_pending_store_survives_reopen_without_reclaim(self):
        p,_source,store,_plan,_added=self.probe(0);r=store.reserve(p.bound)
        self.assertEqual(store.read()[0]['reserved_posts'],2)
        with self.assertRaises(StoreError):InitialMarkStyleStore(store.backend).reserve(p.bound)
        self.assertTrue(store.owns(r,'create_pending'));self.assertNotIn(p.body['markText'].encode(),store.backend.data)
    def test_readonly_does_not_reserve_or_dispatch(self):
        p,source,store,plan,_added=self.probe(0)
        with patch('verify_highlight_trial.reading_position',return_value=plan.web_position):r=p.run({})
        self.assertEqual(r['account_data_posts'],0);self.assertEqual(store.read(),(None,None));source.writer.request.assert_not_called()
    def test_default_does_not_open_credentials_or_network(self):
        with patch('verify_initial_mark_style.SessionStore',side_effect=AssertionError('offline')),redirect_stdout(io.StringIO()) as out:self.assertEqual(main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_pending_initial_style_blocks_all_other_trial_exclusions(self):
        import verify_native_thought_trial as task
        factories=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore',
            'NativeShelfTrialStore','NativeFinishTrialStore','FlagTrialStore','NativeFlagTrialStore','MarkStyleTrialStore','HighlightTrialStore','BookmarkTrialStore','InitialMarkStyleStore','MarkColorStore','NonemptyMarksStore','ReadtimeTrialStore')
        from contextlib import ExitStack
        with ExitStack() as stack:
            mocks={k:stack.enter_context(patch.object(task,k)) for k in factories}
            for m in mocks.values():m.return_value.pending.return_value=False;m.return_value.read.return_value=(None,None)
            self.assertFalse(task.other_pending());mocks['InitialMarkStyleStore'].return_value.read.return_value=({'phase':'create_pending'},None)
            self.assertTrue(task.other_pending(exclude_native_highlight=True,exclude_bookmark=True,exclude_native_bookmark=True,exclude_native_shelf=True,exclude_native_finish=True))


if __name__=='__main__':unittest.main()
