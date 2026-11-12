"""Offline bindings, intent isolation, duplex steps and read-only recovery."""
from contextlib import ExitStack
from contextlib import redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
import unittest
from unittest.mock import Mock,patch
from native_finish_trial import bind,check,validate_plan
from secure_native_finish_trial import NativeFinishTrialStore
from secure_native_shelf_trial import NativeShelfTrialStore
from secure_shelf_experiment import canonical
from secure_weread_session import StoreError
from test_secure_native_session import Backend,credentials
from test_native_shelf_trial import source
from run_native_finish_trial import FLAGS,validate_stage,validate_payload
import verify_native_finish_trial as task


def progress():return dict(book=dict(bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=100,progress=37.5))
def plan():return bind('900000','41',hashlib.sha256(canonical(credentials())).hexdigest(),source(),progress())
def marked():
    value=source();value['books'][0]['finishReading']=1;return value
def stage(armed):
    value=dict.fromkeys(FLAGS,True);value.update(result='PASS',phase='complete',permit_writes=armed,native_gets=15 if armed else 5,
        native_posts=2 if armed else 0,denied=0,screenshots=0,failed_line=0,shelf_books=2,profile_files_audited=8)
    for key in ('second_preview','cache_verified','journal_before_posts'):value[key]=armed
    return value


class ModelTests(unittest.TestCase):
    def test_exact_two_metadata_directions_and_original_position_are_bound(self):
        p=plan();self.assertTrue(check(p,source(),progress(),False));self.assertTrue(check(p,marked(),progress(),True))
        self.assertEqual(p['mark']['before_hash'],p['restore']['after_hash']);self.assertEqual(p['mark']['after_hash'],p['restore']['before_hash'])
        self.assertNotEqual(p['mark']['request_hash'],p['restore']['request_hash'])
    def test_changed_flags_members_groups_or_subpercent_position_are_refused(self):
        for kind in ('flag','member','group','position'):
            value=marked();point=progress()
            if kind=='flag':value['books'][1]['secret']=0
            elif kind=='member':value['books'].pop()
            elif kind=='group':value['archive'][0]['name']='Changed'
            else:point['book']['progress']+=.00001
            with self.subTest(kind=kind),self.assertRaises(ValueError):check(plan(),value,point,True)
    def test_preexisting_finished_unknown_source_and_malformed_binding_are_rejected(self):
        with self.assertRaises(ValueError):bind('900000','41','a'*64,marked(),progress())
        for mutate in (lambda p:p.update(extra=True),lambda p:p['mark'].update(desired=1),lambda p:p['restore'].update(position_hash='f'*64)):
            value=deepcopy(plan());mutate(value)
            with self.assertRaises(ValueError):validate_plan(value)
        value=deepcopy(plan());value['mark']['after_hash']=value['mark']['before_hash'];value['restore']['before_hash']=value['restore']['after_hash']
        with self.assertRaises(ValueError):validate_plan(value)


class ScopeTests(unittest.TestCase):
    def test_distinct_scope_blocks_relaunch_and_rejects_shelf_protocol(self):
        backend=Backend();store=NativeFinishTrialStore(backend);r=store.reserve(plan())
        self.assertTrue(NativeFinishTrialStore(backend).pending());self.assertTrue(store.owns(r,plan()))
        self.assertEqual(store.read()[0]['reserved_posts'],2)
        with self.assertRaises(StoreError):store.reserve(plan())
        with self.assertRaises(StoreError):NativeShelfTrialStore(backend).read()
        self.assertNotEqual(store.service,NativeShelfTrialStore.service)
        with self.assertRaises(StoreError):store.finish(r)
        store.finish(r,restored_verified=True);self.assertFalse(store.pending())
    def test_shared_pending_check_cannot_bypass_any_other_scope(self):
        import verify_native_thought_trial as shared
        with ExitStack() as contexts:
            a=contexts.enter_context(patch.object(shared,'AnnotationExperimentStore'))
            f=contexts.enter_context(patch.object(shared,'FinishExperimentStore'))
            s=contexts.enter_context(patch.object(shared,'ShelfExperimentStore'))
            p=contexts.enter_context(patch.object(shared,'PositionExperimentStore'))
            h=contexts.enter_context(patch.object(shared,'HighlightTrialStore'))
            style=contexts.enter_context(patch.object(shared,'MarkStyleTrialStore'))
            book=contexts.enter_context(patch.object(shared,'BookmarkTrialStore'))
            shelf=contexts.enter_context(patch.object(shared,'NativeShelfTrialStore'))
            finish=contexts.enter_context(patch.object(shared,'NativeFinishTrialStore'))
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
            contexts.enter_context(patch.object(shared,'NativeCloseTrialStore')).return_value.pending.return_value=False
            contexts.enter_context(patch.object(shared,'NativeTimerTrialStore')).return_value.pending.return_value=False
            native_txt.return_value.pending.return_value=native_txt_roundtrip.return_value.pending.return_value=False
            txt_zero.return_value.pending.return_value=False
            txt_full.return_value.pending.return_value=False
            flags.return_value.pending.return_value=native_flags.return_value.pending.return_value=False
            readtime.return_value.read.return_value=nonempty.return_value.read.return_value=initial.return_value.read.return_value=colors.return_value.read.return_value=(None,None)
            for factory in (a,f,s,p,shelf):factory.return_value.pending.return_value=False
            for factory in (h,style,book):factory.return_value.read.return_value=(None,None)
            finish.return_value.pending.return_value=True
            self.assertTrue(shared.other_pending());self.assertFalse(shared.other_pending(exclude_native_finish=True))
            shelf.return_value.pending.return_value=True;self.assertTrue(shared.other_pending(exclude_native_finish=True))
    def test_only_verified_original_state_can_resolve_without_writing(self):
        store=NativeFinishTrialStore(Backend());store.reserve(plan());probe=Mock();probe.request.side_effect=[source(),progress(),source(),progress()]
        result=task.resolve(credentials(),store,probe);self.assertEqual(probe.request.call_count,4);self.assertFalse(store.pending())
        self.assertEqual(result['account_data_posts'],0);self.assertFalse(result['prior_native_trial_success_claimed'])
        store.reserve(plan());probe.request.side_effect=[marked(),progress()]
        with self.assertRaises(ValueError):task.resolve(credentials(),store,probe)
        self.assertTrue(store.pending())
    def test_foreign_owner_cannot_resolve_or_read_private_target(self):
        store=NativeFinishTrialStore(Backend());store.reserve(plan());probe=Mock()
        with self.assertRaises(ValueError):task.resolve(dict(credentials(),vid='900001'),store,probe)
        probe.request.assert_not_called()


class FramingTests(unittest.TestCase):
    def test_stage_requires_all_native_confirmations_correct_slots_and_cleanup(self):
        for armed in (False,True):self.assertEqual(validate_stage(stage(armed),armed),stage(armed))
        for field,bad in (('native_posts',1),('native_confirmations',False),('denied',1),('screenshots',1)):
            with self.assertRaises(ValueError):validate_stage(dict(stage(True),**{field:bad}),True)
    def test_input_is_bound_to_exact_account_operation_and_mock(self):
        p=plan();value=dict(credentials=credentials(),book_id='41',expected_metadata=dict(bookId='41',title='Synthetic'),shelf_books=2,
            mark=p['mark'],restore=p['restore'],permit_writes=False,rpc_token='a'*32)
        validate_payload(value,False,None)
        for field,bad in (('permit_writes',True),('shelf_books',True),('rpc_token','bad'),('book_id','42')):
            with self.assertRaises(Exception):validate_payload(dict(value,**{field:bad}),False,None)
        with self.assertRaises(ValueError):validate_payload(dict(value,mock_port=1234),False,1234)
    def test_failed_installation_or_unverified_stage_cannot_be_a_success(self):
        for value in (dict(result='PASS',profile_removed=False,installed=dict(files=250,bytes_match=True),stage=stage(True)),
                      dict(result='PASS',profile_removed=True,installed=dict(files=250,bytes_match=False),stage=stage(True))):
            with self.assertRaises(ValueError):task.validate_result(value,True)


class ExecutionTests(unittest.TestCase):
    def fixture(self):
        probe=task.FinishTrialProbe();probe.bound=plan();probe.payload=dict(credentials=credentials(),book_id='41',expected_metadata=dict(bookId='41',title='Synthetic'),
            shelf_books=2,mark=plan()['mark'],restore=plan()['restore']);probe.read=Mock(return_value=True)
        store=NativeFinishTrialStore(Backend());child=Mock(stdin=io.BytesIO(),stdout=io.BytesIO());child.wait.return_value=0;child.poll.return_value=0
        return probe,store,child
    def execute(self,*,armed=True,bad_step=False,conflict=False):
        probe,store,child=self.fixture();events=[('STEP',dict(seq=2 if bad_step else 1)),('STEP',dict(seq=2))] if armed else []
        if conflict:probe.read.side_effect=[True,ValueError('conflict')];child.poll.return_value=None
        events.append(('RESULT',dict(result='PASS',profile_removed=True,installed=dict(files=250,bytes_match=True),stage=stage(armed))))
        with patch.object(task.subprocess,'Popen',return_value=child),patch.object(task,'Frames') as frames,patch.object(task,'stop'):
            frames.return_value.next.side_effect=events
            try:result=task.run(probe,credentials(),store,['synthetic-native'],armed=armed)
            except task.TrialFailure as e:result=e
        return result,probe,store,child
    def test_each_native_post_is_followed_by_host_read_before_next_step(self):
        result,probe,store,child=self.execute();self.assertEqual(result['account_data_posts'],2);self.assertFalse(store.pending())
        self.assertEqual([c.args[1] for c in probe.read.call_args_list],[False,True,False,False])
        self.assertIn(b'"seq":1,"ok":true',child.stdin.getvalue());self.assertIn(b'"seq":2,"ok":true',child.stdin.getvalue())
    def test_dry_run_reserves_zero_and_checks_original_state(self):
        result,probe,store,_child=self.execute(armed=False);self.assertEqual(result['reserved_posts'],0);self.assertFalse(store.pending())
        self.assertEqual(probe.read.call_count,2)
    def test_wrong_step_or_host_change_blocks_restore_and_keeps_intent(self):
        for options in (dict(bad_step=True),dict(conflict=True)):
            result,_probe,store,child=self.execute(**options);self.assertIsInstance(result,task.TrialFailure);self.assertTrue(store.pending())
            self.assertNotIn(b'"seq":1,"ok":true',child.stdin.getvalue())
    def test_stopped_trial_or_changed_grant_cannot_launch_native_reader(self):
        probe,store,_child=self.fixture();store.reserve(plan())
        with patch.object(task.subprocess,'Popen') as launch,self.assertRaises(ValueError):task.run(probe,credentials(),store,['native'],armed=True)
        launch.assert_not_called();probe.read.assert_not_called()
        store=NativeFinishTrialStore(Backend())
        with patch.object(task.subprocess,'Popen') as launch,self.assertRaises(ValueError):task.run(probe,dict(credentials(),accessToken='changed'),store,['native'],armed=True)
        launch.assert_not_called();self.assertFalse(store.pending())
    def test_host_has_no_data_post_route(self):
        probe=task.FinishTrialProbe();probe.targets={'41'}
        with self.assertRaises(ValueError):probe.request('finish_write','https://i.weread.qq.com/book/markstatus',dict(bookId='41'),credentials())
    def test_offline_default_does_not_read_keychain(self):
        with patch.object(task,'SessionStore') as login,patch.object(task,'NativeFinishTrialStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        login.assert_not_called();store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
