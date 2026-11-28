"""Offline exact styles, durable claims and unknown-result no-replay checks."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock,patch
from annotation_experiment_model import digest
from highlight_trial_model import PendingObservation
from mark_style_trial_model import bind,observe_change,style_body,row_target,validate_plan,PHASES
from secure_highlight_trial import HighlightTrialStore
from secure_mark_style_trial import MarkStyleTrialStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_selection_trial import fixture
from test_highlight_trial import state
from verify_highlight_trial import HighlightProbe
from verify_eink_login import ProbeError
from verify_mark_style_trial import StyleProbe,main


class StyleTests(unittest.TestCase):
    def setup_probe(self):
        _payload,plan=fixture();source=Mock();source.plan=plan;source.prepare.return_value=plan
        source.baseline.return_value=plan.baseline
        highlight=HighlightProbe(source,HighlightTrialStore(Backend()),sleep=lambda _s:None)
        store=MarkStyleTrialStore(Backend());probe=StyleProbe(highlight,store);probe.prepare({},{});
        added=state(plan,highlight.body);return probe,source,store,plan,added

    def test_exact_style_body_preserves_existing_color(self):
        p,_s,_store,_plan,added=self.setup_probe();row=added['marks']['updated']['new-highlight'];row['colorStyle']=3
        self.assertEqual(style_body(row,2),dict(bookmarkId='new-highlight',style=2,colorStyle=3))
        for style in (True,-1,3,'2',None):
            with self.subTest(style=style),self.assertRaises(ValueError):style_body(row,style)
        with self.assertRaises(ValueError):style_body(dict(row,type=0),1)
        with self.assertRaises(ValueError):validate_plan(dict(p.bound,extra=True))

    def test_only_the_new_row_style_can_change(self):
        p,_s,_store,plan,added=self.setup_probe();previous=added['marks']['updated']['new-highlight'];target=row_target(previous)
        current=deepcopy(added);current['marks']['updated']['new-highlight']['style']=0
        found,row=observe_change(plan.baseline,current,p.highlight.body,target,previous,0)
        self.assertEqual(found,row_target(row));self.assertEqual(row['style'],0)
        for field,value in [('colorStyle',1),('markText','changed'),('createTime',1),('bookmarkId','other'),('range','1-20')]:
            bad=deepcopy(current);bad['marks']['updated']['new-highlight'][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):observe_change(plan.baseline,bad,p.highlight.body,target,previous,0)
        current['thoughts']['other']={}
        with self.assertRaises(ValueError):observe_change(plan.baseline,current,p.highlight.body,target,previous,0)

    def test_lag_is_retryable_only_when_full_previous_state_matches(self):
        p,_s,_store,plan,added=self.setup_probe();row=added['marks']['updated']['new-highlight'];target=row_target(row)
        with self.assertRaises(PendingObservation):observe_change(plan.baseline,added,p.highlight.body,target,row,0)
        added['shelf']['other']={}
        with self.assertRaises(ValueError) as error:observe_change(plan.baseline,added,p.highlight.body,target,row,0)
        self.assertNotIsInstance(error.exception,PendingObservation)

    def test_complete_four_write_sequence_and_private_original_protection(self):
        p,source,store,plan,added=self.setup_probe()
        straight=deepcopy(added);straight['marks']['updated']['new-highlight']['style']=0
        wave=deepcopy(added);wave['marks']['updated']['new-highlight']['style']=2
        source.notes.observe.side_effect=[added,added,straight,straight,wave,wave,plan.baseline]
        with patch('verify_mark_style_trial.reading_position',return_value=plan.web_position):result=p.run({},apply=True)
        self.assertEqual(result['account_data_posts'],4);self.assertEqual(result['independent_steps'],4)
        self.assertEqual(store.read(),(None,None));self.assertEqual(source.notes.observe.call_count,7)
        calls=source.writer.request.call_args_list
        self.assertEqual([c.args[1].split('.com')[1] for c in calls],['/book/addBookmark','/book/updateBookmark','/book/updateBookmark','/book/removeBookmark'])
        self.assertEqual(calls[1].args[2],dict(bookmarkId='new-highlight',style=0,colorStyle=0))
        self.assertEqual(calls[2].args[2]['style'],2)

    def test_lost_http_receipts_are_read_not_replayed(self):
        p,source,store,plan,added=self.setup_probe();straight=deepcopy(added);straight['marks']['updated']['new-highlight']['style']=0
        wave=deepcopy(added);wave['marks']['updated']['new-highlight']['style']=2
        source.notes.observe.side_effect=[added,added,added,straight,straight,wave,wave,plan.baseline]
        source.writer.request.side_effect=ProbeError('lost receipt')
        with patch('verify_mark_style_trial.reading_position',return_value=plan.web_position):result=p.run({},apply=True)
        self.assertEqual(result['account_data_posts'],4);self.assertEqual(source.writer.request.call_count,4);self.assertEqual(store.read(),(None,None))

    def test_unknown_style_response_stops_without_delete_or_retry(self):
        p,source,store,_plan,added=self.setup_probe();source.notes.observe.side_effect=[added,added,added,added,added]
        with self.assertRaises(PendingObservation):p.run({},apply=True)
        self.assertEqual(p.posts,2);self.assertEqual(store.read()[0]['phase'],'straight_pending')
        with self.assertRaises(StoreError):store.reserve(p.bound)
        with self.assertRaises(ValueError):p.post({},'straight_pending','/book/updateBookmark',style_body(p.row,0))
        self.assertEqual(source.writer.request.call_count,2)

    def test_reservation_transitions_are_strict_and_persist_no_quote(self):
        p,_s,store,_plan,added=self.setup_probe();r=store.reserve(p.bound)
        self.assertEqual(store.read()[0]['reserved_posts'],4)
        self.assertNotIn(p.highlight.body['markText'].encode(),store.backend.data)
        with self.assertRaises(StoreError):store.advance(r,'straight')
        target=row_target(added['marks']['updated']['new-highlight'])
        for phase in PHASES[1:]:
            old=r;r=store.advance(r,phase,target=target if phase in ('created','straight','wave') else None)
            self.assertFalse(store.owns(old,phase));self.assertTrue(store.owns(r,phase))
        store.finish(r);self.assertEqual(store.read(),(None,None))

    def test_wrong_new_target_cannot_replace_claimed_target(self):
        p,_s,store,_plan,added=self.setup_probe();r=store.reserve(p.bound);target=row_target(added['marks']['updated']['new-highlight'])
        r=store.advance(r,'created',target=target);r=store.advance(r,'straight_pending')
        with self.assertRaises(StoreError):store.advance(r,'straight',target=dict(target,id='old-mark'))

    def test_readonly_never_reserves_or_dispatches(self):
        p,source,store,plan,_added=self.setup_probe()
        with patch('verify_mark_style_trial.reading_position',return_value=plan.web_position):result=p.run({})
        self.assertEqual(result['account_data_posts'],0);self.assertEqual(store.read(),(None,None));source.writer.request.assert_not_called()

    def test_default_never_loads_credentials_or_network(self):
        with patch('verify_mark_style_trial.SessionStore',side_effect=AssertionError('offline')),redirect_stdout(io.StringIO()) as out:self.assertEqual(main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
