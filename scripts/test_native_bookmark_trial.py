"""Native point protocols, two-slot handshakes and read-only reconciliation."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock,patch
from annotation_experiment_model import digest
from bookmark_trial_model import bind,observe
from bookmark_trial_recovery import reconcile_deleted,finish_reconcile
from native_bookmark_trial import validate_payload,validate_stage
from secure_bookmark_trial import BookmarkTrialStore
from secure_highlight_trial import HighlightTrialStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_selection_trial import fixture
from test_owner_selection_preview import RAW
import test_native_highlight_trial as helpers
import verify_native_bookmark_trial as task


def runner(armed):
    value=helpers.runner(armed);value['installed_files']=249
    value['stage']['selection_trial'].update(viewport_bound=True,bookmark_navigation=armed,view_mode_restored=True)
    return value


class NativeBookmarkTests(unittest.TestCase):
    def fixture(self):
        payload,plan=fixture();source=Mock();source.payload=payload;source.plan=plan;source.prepare.return_value=plan
        source.baseline.return_value=deepcopy(plan.baseline);source.web.cookies={};source.web.shards=dict.fromkeys(('e_0','e_1','e_3'),'synthetic')
        probe=task.NativeBookmarkProbe(source,BookmarkTrialStore(Backend()))
        with patch('verify_bookmark_trial.decode_content_shards',return_value=RAW):probe.prepare({},{})
        added=deepcopy(plan.baseline);added['marks']['updated']['new-bookmark']=dict(bookmarkId='new-bookmark',type=0,chapterUid=2,style=0,range=probe.body['range'])
        target=observe(plan.baseline,added,probe.body)
        probe.read=Mock(side_effect=[(target,added),(target,added),(None,plan.baseline),(None,plan.baseline)])
        return probe,BookmarkTrialStore(Backend(),native=True),target

    def run_mock(self,armed=True,events=None,p=None,s=None,on_spawn=None,on_reply=None):
        if p is None:p,s,_target=self.fixture()
        child=Mock();child.wait.return_value=0;child.poll.return_value=None
        if events is None:events=([('STEP',dict(seq=n,created_id='new-bookmark')) for n in (1,2)] if armed else [('STEP',dict(seq=0,preview=p.body))])+[('RESULT',runner(armed))]
        with patch.object(task.subprocess,'Popen',side_effect=lambda *_a,**_k:(on_spawn() if on_spawn else None) or child),patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'reply',side_effect=on_reply) as ack,patch.object(task,'stop'),patch.object(task,'reading_position',return_value=p.source.plan.web_position):
            frames.return_value.next.side_effect=events
            result=task.run(p,{},s,['synthetic'],armed=armed)
        return result,p,s,ack

    def test_two_slots_exist_before_spawn_and_host_read_releases_only_new_delete(self):
        p,s,target=self.fixture()
        def spawn():self.assertEqual((s.read()[0]['phase'],s.read()[0]['reserved_posts']),('create_pending',2))
        def ack(_stream,value):
            self.assertEqual(s.read()[0]['phase'],'delete_pending');self.assertEqual(s.read()[0]['target'],target)
            self.assertEqual(value['created_id'],'new-bookmark')
        result,p,s,ack=self.run_mock(p=p,s=s,on_spawn=spawn,on_reply=ack)
        self.assertEqual(result['account_data_posts'],2);self.assertEqual(ack.call_count,2);self.assertEqual(p.read.call_count,4)
        self.assertEqual(s.read(),(None,None));p.source.writer.request.assert_not_called()

    def test_dry_run_has_no_reservation_or_python_dispatch(self):
        result,p,s,ack=self.run_mock(False)
        self.assertEqual(result['account_data_posts'],0);self.assertEqual(s.read(),(None,None));p.read.assert_not_called()
        self.assertEqual(ack.call_args.args[1],dict(seq=0,ok=True));p.source.writer.request.assert_not_called()

    def test_invalid_host_steps_stop_without_replay(self):
        for event in (dict(seq=1,created_id='old-mark'),dict(seq=True,created_id='new-bookmark'),dict(seq=2,created_id='new-bookmark')):
            p,s,_target=self.fixture()
            with self.subTest(event=event),self.assertRaises(task.TrialFailure):self.run_mock(events=[('STEP',event)],p=p,s=s)
            self.assertEqual(s.read()[0]['phase'],'create_pending');p.read.assert_not_called()
            with patch.object(task.subprocess,'Popen') as launch,self.assertRaises(ValueError):task.run(p,{},s,['synthetic'],armed=True)
            launch.assert_not_called()

    def test_mismatched_preview_does_not_create_an_intent(self):
        p,s,_target=self.fixture()
        with self.assertRaises(task.TrialFailure):self.run_mock(False,[('STEP',dict(seq=0,preview=dict(p.body,style=1)))],p,s)
        self.assertEqual(s.read(),(None,None))

    def test_prototype_highlight_and_native_bookmark_protocols_cannot_share_slots(self):
        p,s,_target=self.fixture();native=bind(p.source.plan.bound,p.body,native=True)
        with self.assertRaises(ValueError):s.reserve(p.bound)
        with self.assertRaises(ValueError):p.store.reserve(native)
        with self.assertRaises(ValueError):HighlightTrialStore(Backend(),native=True).reserve(native)
        receipt=s.reserve(native)
        with self.assertRaises(StoreError):s.reserve(native)
        self.assertTrue(s.owns(receipt,'create_pending'))

    def test_payload_rejects_guessed_fields_types_reference_and_point(self):
        p,_s,_target=self.fixture();value=task.payload(p,True);validate_payload(value,True,None)
        for field,content in [('style',1),('type',True),('range','01'),('chapterUid',True),('bookVersion',True),('colorStyle',0),('chapterIdx',2)]:
            bad=deepcopy(value);bad['bookmark_trial']['create_body'][field]=content
            with self.subTest(field=field),self.assertRaises(ValueError):validate_payload(bad,True,None)
        bad=deepcopy(value);bad['bookmark_trial']['reference']['source']['raw_sha256']='a'*64
        with self.assertRaises(ValueError):validate_payload(bad,True,None)
        bad=deepcopy(value);bad['highlight_trial']={}
        with self.assertRaises(ValueError):validate_payload(bad,True,None)

    def test_receipt_requires_viewport_and_navigation_proofs(self):
        value=runner(True);validate_stage(value['stage'],True)
        for field,content in [('viewport_bound',False),('bookmark_navigation',False),('view_mode_restored',False),('native_posts',3),('steps',True),('private_source','secret')]:
            bad=deepcopy(value);bad['stage']['selection_trial'][field]=content
            with self.subTest(field=field),self.assertRaises(ValueError):validate_stage(bad['stage'],True)
        with self.assertRaises(ValueError):validate_stage(helpers.runner(True)['stage'],True)

    def test_shelf_diagnostics_are_bounded_and_allowed_only_for_failed_shelf_stage(self):
        value=runner(False)['stage'];value.update(result='UNVERIFIED',phase='shelf')
        value['selection_trial']['shelf_check']=dict(fetches=1,fetch_error=1,cache_calls=0,metadata_valid=False,cached=False,source=0,worker_result=2)
        validate_stage(value,False,False)
        for change in (None,dict(value['selection_trial']['shelf_check'],private='secret'),dict(value['selection_trial']['shelf_check'],fetches=True)):
            bad=deepcopy(value);bad['selection_trial']['shelf_check']=change
            with self.assertRaises(ValueError):validate_stage(bad,False,False)
        with self.assertRaises(ValueError):validate_stage(value,False)

    def test_python_bookmark_transport_cannot_dispatch_a_native_intent(self):
        from verify_bookmark_trial import BookmarkProbe
        p,s,_target=self.fixture();probe=BookmarkProbe(p.source,s)
        with self.assertRaises(ValueError):probe.prepare({},{})
        with self.assertRaises(ValueError):probe.post({},'create_pending','/book/addBookmark',p.body)
        with self.assertRaises(ValueError):probe.run({},apply=True)
        self.assertEqual(s.read(),(None,None));p.source.writer.request.assert_not_called()

    def test_native_ambiguous_delete_can_only_clear_by_exact_readonly_reconstruction(self):
        p,s,target=self.fixture();receipt=s.reserve(bind(p.source.plan.bound,p.body,native=True))
        receipt=s.advance(receipt,'created',target=target);s.advance(receipt,'delete_pending')
        p.source.notes.observe.return_value=p.source.plan.baseline;identity=dict(vid=p.source.plan.bound['owner'])
        with patch('bookmark_trial_recovery.decode_content_shards',return_value=RAW):recovered=reconcile_deleted(identity,identity,s,digest(s.read()[0]['plan']),p.source)
        with patch('verify_owner_reading.reading_position',return_value=p.source.plan.web_position):result=finish_reconcile(recovered,identity)
        self.assertEqual(result['account_data_posts'],0);self.assertEqual(s.read(),(None,None));p.source.writer.request.assert_not_called()

    def test_other_scope_still_blocks_when_native_bookmark_is_explicitly_excluded(self):
        import verify_native_thought_trial as shared
        for native in (False,True):
            with patch.object(shared,'AnnotationExperimentStore') as a,patch.object(shared,'FinishExperimentStore') as f,patch.object(shared,'ShelfExperimentStore') as s,patch.object(shared,'PositionExperimentStore') as pos,patch.object(shared,'HighlightTrialStore') as h,patch.object(shared,'MarkStyleTrialStore') as styles,patch.object(shared,'BookmarkTrialStore') as bookmarks,patch.object(shared,'NativeShelfTrialStore') as shelf_trial,patch.object(shared,'NativeFinishTrialStore') as finish_trial,patch.object(shared,'InitialMarkStyleStore') as initial,patch.object(shared,'MarkColorStore') as colors,patch.object(shared,'NonemptyMarksStore') as nonempty:
                nonempty.return_value.read.return_value=initial.return_value.read.return_value=colors.return_value.read.return_value=(None,None)
                finish_trial.return_value.pending.return_value=False
                shelf_trial.return_value.pending.return_value=False
                for factory in (a,f,s,pos):factory.return_value.pending.return_value=False
                h.return_value.read.return_value=styles.return_value.read.return_value=(None,None)
                bookmarks.side_effect=lambda **kw:Mock(read=Mock(return_value=({'phase':'delete_pending'} if kw['native']==native else None,None)))
                self.assertEqual(shared.other_pending(exclude_native_bookmark=True),not native)

    def test_default_does_not_open_account_or_keychain(self):
        with patch.object(task,'SessionStore') as login,patch.object(task,'BookmarkTrialStore') as store,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        login.assert_not_called();store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['account_data_posts'],0)


if __name__=='__main__':unittest.main()
