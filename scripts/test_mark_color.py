"""All palette values, atomic claims, exact changes and unknown-result stops."""
from contextlib import redirect_stdout,ExitStack
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock,patch
from annotation_experiment_model import digest
from mark_color_model import STEPS,create_body,color_body,validate_plan,dispatch_hash,restored_projection
from secure_mark_color import MarkColorStore,SERVICE
from secure_initial_mark_style import SERVICE as INITIAL_SERVICE
from secure_highlight_trial import HighlightTrialStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_selection_trial import fixture
from verify_eink_login import ProbeError
from verify_eink_login import BASE
from verify_annotation_experiment import AnnotationProbe,query
from verify_highlight_trial import HighlightProbe
from verify_mark_color import ColorProbe,main


class ColorTests(unittest.TestCase):
    def probe(self):
        _payload,plan=fixture();source=Mock();source.plan=plan;source.prepare.return_value=plan;source.baseline.return_value=plan.baseline
        high=HighlightProbe(source,HighlightTrialStore(Backend()),sleep=lambda _s:None)
        store=MarkColorStore(Backend());p=ColorProbe(high,store);p.prepare({},{})
        current=deepcopy(plan.baseline)
        def dispatch(_stage,url,body,_credentials):
            if url.endswith('/book/addBookmark'):
                key='fresh-color-'+str(p.posts);row={k:v for k,v in body.items() if k not in ('bookId','bookVersion')}
                row.update(bookmarkId=key,createTime=1794400000+p.posts);current['marks']['updated'][key]=row
            elif url.endswith('/book/updateBookmark'):current['marks']['updated'][body['bookmarkId']].update(style=body['style'],colorStyle=body['colorStyle'])
            else:del current['marks']['updated'][body['bookmarkIds'][0]]
        source.writer.request.side_effect=dispatch;source.notes.observe.side_effect=lambda *_:deepcopy(current)
        return p,source,store,plan,current,dispatch

    def test_create_colors_and_update_preserve_every_other_request_field(self):
        p,_source,_store,plan,_current,_dispatch=self.probe()
        bodies=[create_body(plan.context,color=c) for c in range(6)]
        for color,body in enumerate(bodies):
            self.assertEqual(dict(body,colorStyle=0),p.highlight.body);self.assertEqual(body['colorStyle'],color)
        row=dict(bookmarkId='fresh',type=1,style=2,colorStyle=0)
        self.assertEqual(color_body(row,3),dict(bookmarkId='fresh',style=2,colorStyle=3))
    def test_invalid_palette_style_unknown_row_and_noop_are_rejected(self):
        p,_source,_store,plan,_current,_dispatch=self.probe();row=dict(bookmarkId='fresh',type=1,style=1,colorStyle=0)
        for value in (True,False,-1,6,'2',None,1.5):
            with self.subTest(value=value),self.assertRaises(ValueError):create_body(plan.context,color=value)
            with self.assertRaises(ValueError):color_body(row,value)
        for bad in (dict(row,type=True),dict(row,type=0),dict(row,style=99),dict(row,colorStyle=None)):
            with self.assertRaises(ValueError):color_body(bad,2)
        with self.assertRaises(ValueError):color_body(row,0)
        self.assertNotEqual(SERVICE,INITIAL_SERVICE);self.assertEqual(p.posts,0)
    def test_fixed_plan_covers_every_initial_and_modified_color(self):
        p,_source,_store,_plan,_current,_dispatch=self.probe()
        self.assertEqual(len(STEPS),16)
        self.assertEqual({c for op,c in STEPS if op=='create'},{1,2,3,4,5})
        self.assertEqual({c for op,c in STEPS if op=='color'},set(range(6)))
        self.assertEqual(len(set(p.bound['creation_hashes'])),6)
        for bad in (dict(p.bound,extra=1),dict(p.bound,protocol='old'),dict(p.bound,creation_hashes=['a'*64]*6)):
            with self.assertRaises(ValueError):validate_plan(bad)
    def test_full_palette_has_six_color_updates_and_only_five_fresh_targets(self):
        p,source,store,plan,current,_dispatch=self.probe()
        with patch('verify_mark_color.reading_position',return_value=plan.web_position):r=p.run({},apply=True)
        self.assertEqual(r['account_data_posts'],16);self.assertEqual(r['independent_steps'],16)
        self.assertEqual(store.read(),(None,None));self.assertEqual(current,plan.baseline);self.assertEqual(source.notes.observe.call_count,32)
        calls=source.writer.request.call_args_list
        self.assertEqual(sum(c.args[1].endswith('/book/addBookmark') for c in calls),5)
        self.assertEqual(sum(c.args[1].endswith('/book/updateBookmark') for c in calls),6)
    def test_original_eighty_get_budget_reproduces_the_stop_before_first_delete(self):
        self.palette_with_real_budget(80,complete=False)
    def test_color_specific_budget_finishes_but_still_enforces_its_limit(self):
        self.palette_with_real_budget(280,complete=True)
        self.assertEqual(AnnotationProbe().max_gets,80)
        for invalid in (True,0,281,'280'):
            with self.assertRaises(ValueError):AnnotationProbe(max_gets=invalid)
    def palette_with_real_budget(self,limit,*,complete):
        p,source,store,plan,current,_dispatch=self.probe();notes=AnnotationProbe(sleep=lambda _s:None,max_gets=limit)
        notes.identity='41';notes.grant=digest({});notes.gets=21;source.notes=notes
        def observe(credentials,stage):
            for url in (BASE+'/shelf/sync',query('41'),BASE+'/book/bookmarklist?bookId=41&synckey=0',BASE+'/book/getProgress?bookId=41'):
                notes.request(stage,url,credentials=credentials)
            return deepcopy(current)
        notes.observe=observe
        def transport(self,stage,_url,_body=None,_credentials=None,_timeout=15):
            self.report['stages'].append(dict(stage=stage,status=200));return {}
        with patch('verify_annotation_experiment.NativeProbe.request',transport),patch('verify_mark_color.reading_position',return_value=plan.web_position):
            if complete:
                result=p.run({},apply=True);self.assertEqual(result['account_data_posts'],16);self.assertEqual(notes.gets,149)
            else:
                with self.assertRaisesRegex(ValueError,'annotation_experiment_request'):p.run({},apply=True)
                self.assertEqual(p.posts,7);self.assertEqual(store.read()[0]['step'],7);self.assertEqual(store.read()[0]['phase'],'pending');self.assertEqual(notes.gets,80)
    def test_claim_is_durable_before_transport_and_never_consumed_twice(self):
        p,source,store,_plan,_current,dispatch=self.probe()
        def checked(*args):
            value,_receipt=store.read();self.assertEqual(value['phase'],'claimed');self.assertEqual(value['dispatch_sha256'],digest(args[2]));dispatch(*args)
        source.writer.request.side_effect=checked;p.receipt=store.reserve(p.bound);old=p.receipt;p.post({},0)
        with self.assertRaises(StoreError):store.claim(old,p.bound['creation_hashes'][1])
        with self.assertRaises(StoreError):store.claim(p.receipt,p.bound['creation_hashes'][1])
        with self.assertRaises(ValueError):p.post({},0)
        self.assertEqual(source.writer.request.call_count,1)
    def test_omitted_or_wrong_body_hash_cannot_claim_a_dispatch(self):
        p,source,store,_plan,_current,_dispatch=self.probe();r=store.reserve(p.bound)
        for value in (None,'a'*64,p.bound['creation_hashes'][2]):
            with self.assertRaises(StoreError):store.claim(r,value)
        self.assertEqual(store.read()[0]['phase'],'pending');source.writer.request.assert_not_called()
        with self.assertRaises(ValueError):dispatch_hash(p.bound,True,None)
    def test_unchanged_color_stops_with_claimed_intent_and_no_later_delete(self):
        p,source,store,_plan,_current,dispatch=self.probe()
        source.writer.request.side_effect=lambda stage,url,body,cred:None if url.endswith('/book/updateBookmark') else dispatch(stage,url,body,cred)
        with self.assertRaises(ValueError):p.run({},apply=True)
        self.assertEqual(p.posts,2);self.assertEqual(store.read()[0]['phase'],'claimed');self.assertEqual(store.read()[0]['step'],1)
        with self.assertRaises(ValueError):ColorProbe(p.highlight,store).prepare({},{})
        with self.assertRaises(ValueError):p.post({},1)
        self.assertEqual(source.writer.request.call_count,2)
    def test_unrelated_field_change_stops_immediately_without_cleanup_write(self):
        p,source,store,_plan,current,dispatch=self.probe()
        def changed(*args):
            dispatch(*args)
            if args[1].endswith('/book/updateBookmark'):next(v for k,v in current['marks']['updated'].items() if k.startswith('fresh-color-'))['markText']='Changed externally'
        source.writer.request.side_effect=changed
        with self.assertRaises(ValueError):p.run({},apply=True)
        self.assertEqual(p.posts,2);self.assertEqual(source.writer.request.call_count,2);self.assertEqual(store.read()[0]['phase'],'claimed')
    def test_lost_http_receipts_are_read_back_without_replay(self):
        p,source,store,plan,_current,dispatch=self.probe()
        def lost(*args):dispatch(*args);raise ProbeError('lost')
        source.writer.request.side_effect=lost
        with patch('verify_mark_color.reading_position',return_value=plan.web_position):r=p.run({},apply=True)
        self.assertEqual(r['account_data_posts'],16);self.assertEqual(store.read(),(None,None));self.assertEqual(source.writer.request.call_count,16)
    def test_reopen_cannot_reserve_or_finish_an_unknown_dispatch(self):
        p,_source,store,_plan,_current,_dispatch=self.probe();r=store.reserve(p.bound);claimed=store.claim(r,p.bound['creation_hashes'][1]);reopened=MarkColorStore(store.backend)
        self.assertEqual(reopened.read()[0]['phase'],'claimed')
        with self.assertRaises(StoreError):reopened.reserve(p.bound)
        with self.assertRaises(StoreError):reopened.finish(claimed)
        self.assertNotIn(p.highlight.body['markText'].encode(),store.backend.data)
    def prefix_deleted(self):
        p,source,store,plan,current,dispatch=self.probe();p.receipt=store.reserve(p.bound)
        for index in range(8):
            p.before({});p.post({},index);p.target,p.row,_value=p.read({},index);p.receipt=store.advance(p.receipt,p.target)
        self.assertEqual(current,plan.baseline);self.assertEqual(store.read()[0]['step'],8)
        high=HighlightProbe(source,HighlightTrialStore(Backend()),sleep=lambda _s:None)
        return ColorProbe(high,store),p,source,store,plan,current,dispatch
    def test_continuation_only_consumes_the_eight_never_claimed_slots(self):
        resumed,old,source,store,plan,current,_dispatch=self.prefix_deleted();resumed.resume({},{})
        self.assertEqual(source.prepare.call_args.kwargs['existing'],old.bound['highlight']['selection'])
        with patch('verify_mark_color.reading_position',return_value=plan.web_position):r=resumed.run_remaining({})
        self.assertEqual(r['account_data_posts'],8);self.assertEqual(r['prior_dispatch_slots'],8)
        self.assertEqual(r['initial_colors_verified'],[2,3,4,5]);self.assertEqual(r['modified_colors_verified'],[])
        self.assertEqual(source.writer.request.call_count,16);self.assertEqual(current,plan.baseline);self.assertEqual(store.read(),(None,None))
        with self.assertRaises(ValueError):resumed.run_remaining({})
    def test_claimed_future_step_or_unverified_target_cannot_resume(self):
        resumed,_old,source,store,_plan,_current,_dispatch=self.prefix_deleted();v,r=store.read()
        store.claim(r,v['plan']['creation_hashes'][2]);before=source.prepare.call_count
        with self.assertRaises(ValueError):resumed.resume({},{})
        self.assertEqual(source.prepare.call_count,before);self.assertEqual(source.writer.request.call_count,8)
        p,source,store,_plan,_current,_dispatch=self.probe();store.reserve(p.bound)
        with self.assertRaises(ValueError):ColorProbe(HighlightProbe(source,HighlightTrialStore(Backend())),store).resume({},{})
        source.writer.request.assert_not_called()
    def test_changed_source_binding_cannot_resume_unused_slots(self):
        resumed,_old,source,_store,_plan,_current,_dispatch=self.prefix_deleted()
        source.plan.context['bookVersion']+=1
        with self.assertRaises(ValueError):resumed.resume({},{})
        self.assertEqual(source.writer.request.call_count,8)
    def test_corrupt_claim_hash_or_count_never_loads_as_eligible(self):
        for key,value in [('dispatch_sha256','b'*64),('reserved_posts',True),('step',True),('phase','complete')]:
            p,_source,store,_plan,_current,_dispatch=self.probe();store.reserve(p.bound)
            row=json.loads(store.backend.data);row[key]=value;store.backend.data=json.dumps(row).encode()
            with self.subTest(key=key),self.assertRaises(StoreError):store.read()
    def test_readonly_does_not_claim_reserve_or_write(self):
        p,source,store,plan,_current,_dispatch=self.probe()
        with patch('verify_mark_color.reading_position',return_value=plan.web_position):r=p.run({})
        self.assertEqual(r['account_data_posts'],0);self.assertEqual(store.read(),(None,None));source.writer.request.assert_not_called()
    def test_cleanup_requires_exact_original_hashes_and_one_unchanged_new_target(self):
        p,_source,_store,plan,current,dispatch=self.probe();p.posts=1
        dispatch('synthetic','/book/addBookmark',create_body(plan.context,color=1),{})
        key=next(k for k in current['marks']['updated'] if k.startswith('fresh-color-'));target=dict(id=key,sha256=digest(current['marks']['updated'][key]))
        current['marks']['chapters'][plan.bound['chapter_uid']]={'chapterUid':int(plan.bound['chapter_uid']),'title':'New descriptor'}
        self.assertTrue(restored_projection(p.bound,current,target));self.assertFalse(restored_projection(p.bound,current))
        bad=deepcopy(current);bad['marks']['updated'][key]['markText']='changed';self.assertFalse(restored_projection(p.bound,bad,target))
        bad=deepcopy(current);bad['marks']['chapters']['999']={'chapterUid':999,'title':'Other descriptor'};self.assertFalse(restored_projection(p.bound,bad,target))
        bad=deepcopy(current);bad['position']['other']=1;self.assertFalse(restored_projection(p.bound,bad,target))
        self.assertTrue(restored_projection(p.bound,plan.baseline))
    def test_offline_default_never_opens_credentials_or_network(self):
        with patch('verify_mark_color.SessionStore',side_effect=AssertionError('offline')),redirect_stdout(io.StringIO()) as out:self.assertEqual(main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_pending_palette_cannot_be_bypassed_by_any_other_trial_exclusion(self):
        import verify_native_thought_trial as task
        factories=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore','NativeShelfTrialStore',
            'NativeFinishTrialStore','MarkStyleTrialStore','HighlightTrialStore','BookmarkTrialStore','InitialMarkStyleStore','MarkColorStore','NonemptyMarksStore','ReadtimeTrialStore')
        with ExitStack() as stack:
            mocks={k:stack.enter_context(patch.object(task,k)) for k in factories}
            for value in mocks.values():value.return_value.pending.return_value=False;value.return_value.read.return_value=(None,None)
            self.assertFalse(task.other_pending());mocks['MarkColorStore'].return_value.read.return_value=({'phase':'claimed'},None)
            self.assertTrue(task.other_pending(exclude_native_highlight=True,exclude_bookmark=True,exclude_native_bookmark=True,exclude_native_shelf=True,exclude_native_finish=True))
            self.assertFalse(task.other_pending(exclude_mark_color=True))
            mocks['InitialMarkStyleStore'].return_value.read.return_value=({'phase':'pending'},None)
            self.assertTrue(task.other_pending(exclude_mark_color=True))


if __name__=='__main__':unittest.main()
