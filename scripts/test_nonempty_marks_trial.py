"""Nonempty originals, exact color/style changes and four irreversible claims."""
from contextlib import ExitStack,redirect_stdout
from copy import deepcopy
import io,json,unittest
from unittest.mock import Mock,patch
from mark_style_trial_model import row_target
from native_highlight_trial import validate_payload,validate_stage
from nonempty_marks_trial import bind,validate_plan
from secure_highlight_trial import HighlightTrialStore
from secure_mark_style_trial import MarkStyleTrialStore
from secure_nonempty_marks_trial import NonemptyMarksStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_selection_trial import fixture
from test_highlight_trial import state
from test_native_highlight_trial import runner
from verify_highlight_trial import HighlightProbe
from verify_nonempty_marks_trial import NonemptyMarksProbe
import verify_nonempty_marks_trial as cli
import verify_native_mark_style_trial as task
import verify_native_thought_trial as shared


def result(armed):
    value=runner(armed);value['stage']['selection_trial'].update(steps=4 if armed else 0,native_posts=4 if armed else 0,
        color_controls=armed,style_controls=armed,style_displays=2 if armed else 0,native_gets=28)
    return value


class NonemptyTests(unittest.TestCase):
    def fixture(self):
        payload,plan=fixture();source=Mock();source.payload=payload;source.plan=plan;source.prepare.return_value=plan
        source.baseline.return_value=deepcopy(plan.baseline);source.web.cookies={}
        high=HighlightProbe(source,HighlightTrialStore(Backend()),sleep=lambda _s:None)
        probe=NonemptyMarksProbe(high,NonemptyMarksStore(Backend()));probe.prepare({},{},select_existing=False)
        one=state(plan,high.body);blue=deepcopy(one);blue['marks']['updated']['new-highlight']['colorStyle']=3
        wave=deepcopy(blue);wave['marks']['updated']['new-highlight']['style']=2
        return probe,source,plan,[one,blue,wave,deepcopy(plan.baseline)]

    def run_mock(self,p,values,armed=True,events=None,on_reply=None):
        source=p.highlight.source;source.notes.observe.side_effect=[v for v in values for _i in range(2)]
        child=Mock();child.wait.return_value=0;child.poll.return_value=None
        if events is None:events=([('STEP',dict(seq=i,created_id='new-highlight')) for i in range(1,5)] if armed else [('STEP',dict(seq=0,preview=p.highlight.body))])+[('RESULT',result(armed))]
        def launch(*_args,**_kw):
            self.assertEqual(p.store.read()[0]['reserved_posts'] if armed else p.store.read()[0],4 if armed else None);return child
        with patch.object(task.subprocess,'Popen',side_effect=launch),patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'reply',side_effect=on_reply) as ack,patch.object(task,'stop'),patch.object(task,'reading_position',return_value=source.plan.web_position):
            frames.return_value.next.side_effect=events
            return task.run(p,{},['synthetic'],armed=armed,color_style=True),ack

    def test_four_native_operations_preserve_originals_and_color_across_style(self):
        p,s,plan,values=self.fixture();phases=[]
        def ack(_stream,value):phases.append(p.store.read()[0]['phase'])
        report,_ack=self.run_mock(p,values,on_reply=ack)
        self.assertEqual(phases,['color_pending','style_pending','delete_pending','delete_pending'])
        self.assertEqual(p.store.read(),(None,None));self.assertTrue(report['color_change_verified']);self.assertEqual(report['account_data_posts'],4)
        self.assertEqual(report['original_mark_count'],1);self.assertEqual(report['original_thought_count'],1)
        self.assertEqual(s.notes.observe.call_count,8);s.writer.request.assert_not_called();self.assertEqual(values[-1],plan.baseline)

    def test_dry_has_no_reservation_or_host_post(self):
        p,s,_plan,values=self.fixture();report,ack=self.run_mock(p,values,False)
        self.assertEqual(report['account_data_posts'],0);self.assertEqual(p.store.read(),(None,None));s.notes.observe.assert_not_called()
        self.assertEqual(ack.call_args.args[1],dict(seq=0,ok=True));s.writer.request.assert_not_called()

    def test_nonempty_plan_rejects_empty_collections_wrong_chapter_and_mutations(self):
        p,_s,plan,_values=self.fixture();self.assertEqual(p.bound['chapter_marks'],1)
        for key in ('marks','thoughts','shelf','position'):
            baseline=deepcopy(plan.baseline);baseline[key]={}
            with self.subTest(key=key),self.assertRaises(ValueError):bind(p.highlight.bound,baseline)
        for key,val in [('chapter_marks',0),('chapter_marks',True),('chapter_marks',2),('protocol','source-highlight-two-styles-remove-v1')]:
            with self.subTest(key=key,val=val),self.assertRaises(ValueError):validate_plan(dict(p.bound,**{key:val}))
        for name in ('mark_count','review_count'):
            value=deepcopy(p.bound);value['highlight']['selection'][name]=0
            with self.assertRaises(ValueError):validate_plan(value)
        value=deepcopy(p.bound);value['highlight']['selection']['chapter_uid']='3'
        with self.assertRaises(ValueError):bind(value['highlight'],plan.baseline)

    def test_old_styles_and_new_intent_cannot_authorize_each_other(self):
        p,_s,_plan,_v=self.fixture();old=MarkStyleTrialStore(Backend(),native=True)
        with self.assertRaises(ValueError):old.reserve(p.bound)
        from mark_style_trial_model import bind as old_bind
        with self.assertRaises(ValueError):p.store.reserve(old_bind(p.highlight.bound,native=True))
        p.store=old
        with patch.object(task.subprocess,'Popen') as launch,self.assertRaises(ValueError):task.run(p,{},['synthetic'],armed=True,color_style=True)
        launch.assert_not_called()

    def test_sequential_cas_target_cannot_be_replaced_or_replayed(self):
        p,_s,_plan,v=self.fixture();store=p.store;r=store.reserve(p.bound);target=row_target(v[0]['marks']['updated']['new-highlight'])
        with self.assertRaises(StoreError):store.advance(r,'color_pending')
        old=r;r=store.advance(r,'created',target=target)
        with self.assertRaises(StoreError):store.advance(old,'created',target=target)
        r=store.advance(r,'color_pending')
        with self.assertRaises(StoreError):store.advance(r,'colored',target=dict(target,id='old-mark'))
        with self.assertRaises(StoreError):NonemptyMarksStore(store.backend).reserve(p.bound)

    def test_original_id_out_of_order_and_bool_sequence_never_release(self):
        for event in (dict(seq=1,created_id='old-mark'),dict(seq=2,created_id='new-highlight'),dict(seq=True,created_id='new-highlight')):
            p,s,_plan,v=self.fixture()
            with self.subTest(event=event),self.assertRaises(task.TrialFailure):self.run_mock(p,v,events=[('STEP',event)])
            self.assertEqual(p.store.read()[0]['phase'],'create_pending');s.notes.observe.assert_not_called()
            with patch.object(task.subprocess,'Popen') as launch,self.assertRaises(ValueError):task.run(p,{},['synthetic'],armed=True,color_style=True)
            launch.assert_not_called()

    def test_unrelated_changes_stop_before_next_dispatch(self):
        for key in ('thoughts','shelf','position','old_mark','chapter'):
            p,_s,_plan,v=self.fixture()
            if key=='old_mark':v[1]['marks']['updated']['old-mark']['markText']='Concurrent edit'
            elif key=='chapter':v[1]['marks']['chapters']['3']='Concurrent edit'
            else:v[1][key]['unrelated']='Concurrent edit'
            with self.subTest(key=key),self.assertRaises(task.TrialFailure):self.run_mock(p,v)
            self.assertEqual(p.store.read()[0]['phase'],'color_pending')

    def test_color_transition_cannot_change_style_or_other_fields(self):
        for key,val in [('style',2),('markText','different'),('range','50-60')]:
            p,_s,_plan,v=self.fixture();v[1]['marks']['updated']['new-highlight'][key]=val
            with self.subTest(key=key),self.assertRaises(task.TrialFailure):self.run_mock(p,v)
            self.assertEqual(p.store.read()[0]['phase'],'color_pending')

    def test_style_transition_cannot_change_color(self):
        p,_s,_plan,v=self.fixture();v[2]['marks']['updated']['new-highlight']['colorStyle']=0
        with self.assertRaises(task.TrialFailure):self.run_mock(p,v)
        self.assertEqual(p.store.read()[0]['phase'],'style_pending')

    def test_lagged_color_read_can_retry_only_reads(self):
        p,s,_plan,v=self.fixture();one,blue=v[:2];p.target=row_target(one['marks']['updated']['new-highlight']);p.row=one['marks']['updated']['new-highlight']
        s.notes.observe.side_effect=[one,blue];target,row,_current=p.read({},color=3)
        self.assertEqual(row['colorStyle'],3);self.assertEqual(target['id'],p.target['id']);self.assertEqual(s.notes.observe.call_count,2);s.writer.request.assert_not_called()

    def test_schema_excludes_empty_originals_and_old_style_receipt(self):
        p,_s,_plan,_v=self.fixture();payload=task.payload(p,True,color_style=True);validate_payload(payload,True,None,color_style=True)
        with self.assertRaises(ValueError):validate_payload(payload,True,None,styles=True)
        for collection in ('highlight_trial','selection_trial'):
            v=deepcopy(payload);v[collection]['original_ids']=[]
            with self.assertRaises(ValueError):validate_payload(v,True,None,color_style=True)
        for changes in ({'style_displays':3},{'color_controls':False},{'native_posts':5},{'phase':'style0'}):
            v=result(True);v['stage']['selection_trial'].update(changes)
            with self.assertRaises(ValueError):validate_stage(v['stage'],True,color_style=True)
        with self.assertRaises(ValueError):validate_payload(payload,True,None,styles=True,color_style=True)
        for mode in (1,'true',None):
            with self.assertRaises(ValueError):validate_stage(result(True)['stage'],True,color_style=mode)

    def test_selector_binds_same_book_and_baseline_before_source(self):
        p,s,plan,_v=self.fixture();selector=Mock();selector.prepare.return_value=Mock(bound={'book_id':'41'},baseline=plan.baseline)
        fresh=NonemptyMarksProbe(p.highlight,NonemptyMarksStore(Backend()),selector)
        fresh.highlight.prepare=Mock(return_value=p.highlight.bound);fresh.prepare({},{})
        self.assertEqual(s.web.requested_book,'41')
        selector.prepare.return_value.baseline=deepcopy(plan.baseline);selector.prepare.return_value.baseline['thoughts']={}
        with self.assertRaises(ValueError):NonemptyMarksProbe(p.highlight,NonemptyMarksStore(Backend()),selector).prepare({},{})

    def test_pending_new_scope_blocks_all_old_exclusions(self):
        factories=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore','NativeShelfTrialStore','NativeFinishTrialStore','FlagTrialStore','NativeFlagTrialStore','TxtFullSummaryStore','TxtZeroTimeStore','MarkStyleTrialStore','HighlightTrialStore','BookmarkTrialStore','InitialMarkStyleStore','MarkColorStore','NonemptyMarksStore','ReadtimeTrialStore')
        with ExitStack() as stack:
            mocks={name:stack.enter_context(patch.object(shared,name)) for name in factories}
            for factory in mocks.values():factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None)
            self.assertFalse(shared.other_pending());mocks['NonemptyMarksStore'].return_value.read.return_value=({'phase':'color_pending'},None)
            self.assertTrue(shared.other_pending(exclude_native_highlight=True,exclude_bookmark=True,exclude_native_bookmark=True,exclude_native_shelf=True,exclude_native_finish=True,exclude_mark_color=True))

    def test_final_new_chapter_descriptor_blocks_intent_cleanup(self):
        p,_s,_plan,v=self.fixture();v[3]['marks']['chapters']['2']='New derived descriptor'
        with self.assertRaises(task.TrialFailure):self.run_mock(p,v)
        self.assertEqual(p.store.read()[0]['phase'],'delete_pending')

    def test_corrupt_stored_protocol_and_target_cannot_be_loaded(self):
        p,_s,_plan,v=self.fixture();store=p.store;r=store.reserve(p.bound);raw=r.raw
        for key,val in [('reserved_posts',True),('phase','straight_pending'),('schema',True),('target',row_target(v[0]['marks']['updated']['new-highlight']))]:
            value=json.loads(raw);value[key]=val;store.backend.data=json.dumps(value).encode()
            with self.subTest(key=key),self.assertRaises(StoreError):store.read()
        value=json.loads(raw);value['plan']['protocol']='native-source-highlight-two-styles-remove-v1';store.backend.data=json.dumps(value).encode()
        with self.assertRaises(StoreError):store.read()

    def test_offline_default_does_not_load_accounts(self):
        with patch.object(cli,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:self.assertEqual(cli.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)


if __name__=='__main__':unittest.main()
