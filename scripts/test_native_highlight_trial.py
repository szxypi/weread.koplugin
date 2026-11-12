"""Offline two-slot ownership, exact handshakes and read-only dispatch gates."""
from contextlib import ExitStack
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock,patch
from annotation_experiment_model import digest
from highlight_trial_model import bind_native
from native_highlight_trial import FLAGS,validate_payload,validate_stage
from secure_highlight_trial import HighlightTrialStore
from secure_weread_session import StoreError
from test_owner_reading import COOKIES,stage
from test_secure_native_session import Backend
from test_selection_trial import fixture
from verify_highlight_trial import HighlightProbe
import verify_native_highlight_trial as task


def runner(armed):
    basic=stage();addon=dict.fromkeys(FLAGS,True)
    addon.update(permit_writes=armed,cache_verified=armed,local_pending_kept=not armed,dispatch_blocked=not armed,
        steps=2 if armed else 0,native_gets=15 if armed else 12,native_posts=2 if armed else 0,blocked_posts=0 if armed else 1,native_denied=0,failed_line=0,phase='complete')
    basic['selection_trial']=addon
    return dict(result='PASS',profile_removed=True,installed_files=241,installed_bytes_match=True,stage=basic,cookies=COOKIES.copy())


class TrialTests(unittest.TestCase):
    def fixture(self):
        p,plan=fixture();source=Mock();source.payload=p;source.plan=plan;source.prepare.return_value=plan
        source.baseline.return_value=deepcopy(plan.baseline);source.web.cookies={}
        probe=HighlightProbe(source,HighlightTrialStore(Backend()),sleep=lambda _n:None);probe.prepare({},{})
        target=dict(id='new-highlight',sha256='a'*64)
        probe.read=Mock(side_effect=[(target,plan.baseline),(target,plan.baseline),(None,plan.baseline),(None,plan.baseline)])
        return probe,HighlightTrialStore(Backend(),native=True),target

    def run_mock(self,armed,*,events=None,on_reply=None,on_spawn=None,probe=None,store=None):
        if probe is None:probe,store,_target=self.fixture()
        child=Mock();child.wait.return_value=0;child.poll.return_value=None
        if events is None:events=([('STEP',dict(seq=n,created_id='new-highlight')) for n in (1,2)] if armed else
            [('STEP',dict(seq=0,preview=deepcopy(probe.body)))])+[('RESULT',runner(armed))]
        with patch.object(task.subprocess,'Popen',side_effect=lambda *_a,**_k:(on_spawn() if on_spawn else None) or child),patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'reply',side_effect=on_reply) as ack,patch.object(task,'stop') as stopped,patch.object(task,'reading_position',return_value=probe.source.plan.web_position):
            frames.return_value.next.side_effect=events
            result=task.run(probe,{},store,['synthetic-command'],armed=armed)
        return result,probe,store,ack,stopped

    def test_two_slots_reserved_before_spawn_and_host_proof_precedes_delete_release(self):
        p,s,target=self.fixture();replies=[]
        def spawn():
            state,_r=s.read();self.assertEqual(state['reserved_posts'],2);self.assertEqual(state['phase'],'create_pending')
        def reply(_stream,value):
            state,_r=s.read();self.assertEqual(state['phase'],'delete_pending');self.assertEqual(state['target'],target)
            replies.append(value['seq'])
        result,p,s,_ack,stopped=self.run_mock(True,on_spawn=spawn,on_reply=reply,probe=p,store=s)
        self.assertEqual(result['account_data_posts'],2);self.assertEqual(replies,[1,2]);self.assertEqual(s.read(),(None,None))
        self.assertEqual(p.read.call_count,4);p.source.writer.request.assert_not_called();stopped.assert_called_once()

    def test_dry_run_has_no_reservation_no_host_post_and_only_exact_preview_ack(self):
        result,p,s,ack,_stop=self.run_mock(False)
        self.assertEqual(s.read(),(None,None));self.assertEqual(result['account_data_posts'],0)
        self.assertEqual(ack.call_args.args[1],dict(seq=0,ok=True));p.source.writer.request.assert_not_called()

    def test_prototype_plan_or_store_cannot_arm_native_scope(self):
        p,s,_target=self.fixture()
        with self.assertRaises(ValueError):s.reserve(p.bound)
        native=bind_native(p.source.plan.bound,p.body)
        with self.assertRaises(ValueError):p.store.reserve(native)
        with patch.object(task.subprocess,'Popen') as start,self.assertRaises(ValueError):task.run(p,{},p.store,['synthetic'],armed=True)
        start.assert_not_called()

    def test_pending_restart_cannot_launch_even_with_zero_native_posts(self):
        p,s,_t=self.fixture();s.reserve(bind_native(p.source.plan.bound,p.body));reopened=HighlightTrialStore(s.backend,native=True)
        with patch.object(task.subprocess,'Popen') as start,self.assertRaises(ValueError):task.run(p,{},reopened,['synthetic'],armed=True)
        start.assert_not_called();self.assertEqual(reopened.read()[0]['phase'],'create_pending')

    def test_independent_failure_stops_with_no_next_write_release(self):
        p,s,_t=self.fixture();p.read.side_effect=ValueError('independent mismatch')
        failure=dict(result='UNVERIFIED',profile_removed=True,installed_files=0,installed_bytes_match=False,stage=None,cookies={})
        child=Mock();child.wait.return_value=0;child.poll.return_value=None
        with patch.object(task.subprocess,'Popen',return_value=child),patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'reply') as ack,patch.object(task,'stop') as stopped:
            frames.return_value.next.side_effect=[('STEP',dict(seq=1,created_id='new-highlight')),('RESULT',failure)]
            with self.assertRaises(task.TrialFailure):task.run(p,{},s,['synthetic'],armed=True)
        self.assertEqual(ack.call_args.args[1],dict(seq=1,ok=False));stopped.assert_called_once()
        self.assertEqual(s.read()[0]['phase'],'create_pending')

    def test_original_id_wrong_sequence_or_false_preview_cannot_release_deletion(self):
        for event in (dict(seq=1,created_id='old-mark'),dict(seq=2,created_id='new-highlight'),dict(seq=True,created_id='new-highlight')):
            p,s,_t=self.fixture();failure=dict(result='UNVERIFIED',profile_removed=True,installed_files=0,installed_bytes_match=False,stage=None,cookies={})
            with self.subTest(event=event),self.assertRaises(task.TrialFailure):self.run_mock(True,events=[('STEP',event),('RESULT',failure)],probe=p,store=s)
            self.assertEqual(s.read()[0]['phase'],'create_pending');p.read.assert_not_called()
        p,s,_t=self.fixture();bad=dict(p.body,range='1-2')
        with self.assertRaises(task.TrialFailure):self.run_mock(False,events=[('STEP',dict(seq=0,preview=bad))],probe=p,store=s)
        self.assertEqual(s.read(),(None,None))

    def test_changed_target_after_host_proof_cannot_ack_step_two(self):
        p,s,_t=self.fixture();failure=dict(result='UNVERIFIED',profile_removed=True,installed_files=0,installed_bytes_match=False,stage=None,cookies={})
        with self.assertRaises(task.TrialFailure):self.run_mock(True,events=[('STEP',dict(seq=1,created_id='new-highlight')),('STEP',dict(seq=2,created_id='different')),('RESULT',failure)],probe=p,store=s)
        self.assertEqual(s.read()[0]['phase'],'delete_pending')

    def test_native_success_without_host_web_position_proof_keeps_pending(self):
        p,s,_t=self.fixture();child=Mock();child.wait.return_value=0
        with patch.object(task.subprocess,'Popen',return_value=child),patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'reply'),patch.object(task,'stop'),patch.object(task,'reading_position',return_value={}):
            frames.return_value.next.side_effect=[('STEP',dict(seq=n,created_id='new-highlight')) for n in (1,2)]+[('RESULT',runner(True))]
            with self.assertRaises(task.TrialFailure):task.run(p,{},s,['synthetic'],armed=True)
        self.assertEqual(s.read()[0]['phase'],'delete_pending')

    def test_receipt_and_payload_schemas_exclude_other_writes_and_private_extra_fields(self):
        p,_s,_t=self.fixture();value=task.payload(p,False);validate_payload(value,False,None)
        for change in ('body','original','extra','armed','mock','oversize'):
            invalid=deepcopy(value)
            if change=='body':invalid['highlight_trial']['create_body']['chapterIdx']=2
            elif change=='original':invalid['highlight_trial']['original_ids']=['same','same']
            elif change=='extra':invalid['progress_roundtrip']={}
            elif change=='armed':invalid['selection_trial']['armed']=True
            elif change=='mock':invalid['selection_mock_port']=1234
            else:invalid['highlight_trial']['original_ids']=['synthetic-'+str(n)+'x'*240 for n in range(1500)]
            with self.subTest(change=change),self.assertRaises(ValueError):validate_payload(invalid,False,None)
        for key,new in (('native_posts',3),('native_denied',1),('steps',3),('phase','edit')):
            invalid=runner(True);invalid['stage']['selection_trial'][key]=new
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(invalid['stage'],True)
        self.assertNotIn('cookies',task.public_runner(runner(True)))

    def test_reservation_write_failure_never_starts_reader(self):
        p,s,_t=self.fixture();s.backend.save=lambda _raw:None
        with patch.object(task.subprocess,'Popen') as start,self.assertRaises(StoreError):task.run(p,{},s,['synthetic'],armed=True)
        start.assert_not_called()

    def test_offline_default_never_opens_keychain_or_network(self):
        with patch.object(task,'HighlightTrialStore') as store,patch.object(task,'SessionStore') as login,patch.object(task,'HighlightProbe') as probe,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        for item in (store,login,probe):item.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['account_data_posts'],0)

    def test_other_annotation_trials_stop_while_either_highlight_scope_is_pending(self):
        import verify_native_thought_trial as shared
        for native in (False,True):
            with ExitStack() as contexts:
                a=contexts.enter_context(patch.object(shared,'AnnotationExperimentStore'))
                f=contexts.enter_context(patch.object(shared,'FinishExperimentStore'))
                s=contexts.enter_context(patch.object(shared,'ShelfExperimentStore'))
                p=contexts.enter_context(patch.object(shared,'PositionExperimentStore'))
                h=contexts.enter_context(patch.object(shared,'HighlightTrialStore'))
                styles=contexts.enter_context(patch.object(shared,'MarkStyleTrialStore'))
                bookmarks=contexts.enter_context(patch.object(shared,'BookmarkTrialStore'))
                shelf_trial=contexts.enter_context(patch.object(shared,'NativeShelfTrialStore'))
                finish_trial=contexts.enter_context(patch.object(shared,'NativeFinishTrialStore'))
                initial=contexts.enter_context(patch.object(shared,'InitialMarkStyleStore'))
                colors=contexts.enter_context(patch.object(shared,'MarkColorStore'))
                nonempty=contexts.enter_context(patch.object(shared,'NonemptyMarksStore'))
                readtime=contexts.enter_context(patch.object(shared,'ReadtimeTrialStore'))
                flags=contexts.enter_context(patch.object(shared,'FlagTrialStore'))
                native_flags=contexts.enter_context(patch.object(shared,'NativeFlagTrialStore'))
                txt_full=contexts.enter_context(patch.object(shared,'TxtFullSummaryStore'))
                txt_zero=contexts.enter_context(patch.object(shared,'TxtZeroTimeStore'))
                native_txt=contexts.enter_context(patch.object(shared,'NativeTxtPositionStore'))
                native_txt_roundtrip=contexts.enter_context(patch.object(shared,'NativeTxtRoundtripStore'))
                contexts.enter_context(patch.object(shared,'RawTxtExcerptStore')).return_value.pending.return_value=False
                contexts.enter_context(patch.object(shared,'NativeReaderTrialStore')).return_value.pending.return_value=False
                native_txt.return_value.pending.return_value=native_txt_roundtrip.return_value.pending.return_value=False
                txt_zero.return_value.pending.return_value=False
                txt_full.return_value.pending.return_value=False
                flags.return_value.pending.return_value=native_flags.return_value.pending.return_value=False
                readtime.return_value.read.return_value=nonempty.return_value.read.return_value=initial.return_value.read.return_value=colors.return_value.read.return_value=(None,None)
                finish_trial.return_value.pending.return_value=False
                shelf_trial.return_value.pending.return_value=False
                styles.return_value.read.return_value=(None,None)
                bookmarks.return_value.read.return_value=(None,None)
                for factory in (a,f,s,p):factory.return_value.pending.return_value=False
                h.side_effect=lambda **kw:Mock(read=Mock(return_value=({'phase':'create_pending'} if kw['native']==native else None,None)))
                self.assertTrue(shared.other_pending())
                self.assertEqual(shared.other_pending(exclude_native_highlight=True),not native)

    def prepared_reconcile(self):
        p,s,target=self.fixture();r=s.reserve(bind_native(p.source.plan.bound,p.body));r=s.advance(r,'created',target=target);s.advance(r,'delete_pending')
        return p,s,digest(s.read()[0]['plan'])

    def test_read_only_reconcile_requires_exact_original_plan_then_clears_without_post(self):
        p,s,expected=self.prepared_reconcile()
        with patch.object(task,'reading_position',return_value=p.source.plan.web_position):result=task.reconcile(p.source,{}, {},s,expected)
        self.assertTrue(result['target_absent']);self.assertEqual(s.read(),(None,None));p.source.writer.request.assert_not_called()

    def test_reconcile_rejects_wrong_intent_original_changes_or_moved_web_position(self):
        for mode in ('intent','changed','position'):
            p,s,expected=self.prepared_reconcile()
            if mode=='changed':p.source.plan.bound['marks_sha256']='b'*64
            with self.subTest(mode=mode),patch.object(task,'reading_position',return_value={} if mode=='position' else p.source.plan.web_position),self.assertRaises(ValueError):
                task.reconcile(p.source,{}, {},s,'0'*64 if mode=='intent' else expected)
            self.assertEqual(s.read()[0]['phase'],'delete_pending');p.source.writer.request.assert_not_called()


if __name__=='__main__':unittest.main()
