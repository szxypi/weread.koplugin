"""Offline native shelf intent, full readback, host gate and recovery checks."""
from contextlib import redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
import unittest
from unittest.mock import Mock,patch
from native_shelf_trial import bind,check,validate_plan
from secure_native_shelf_trial import NativeShelfTrialStore
from secure_shelf_experiment import canonical,fingerprint
from secure_weread_session import StoreError
from test_secure_native_session import Backend,credentials
from test_owner_shelf_membership import stage
from verify_owner_shelf_membership import members_digest
import verify_native_shelf_trial as task


def source():
    return dict(books=[dict(bookId='41',title='Original',finishReading=0,secret=0),
                       dict(bookId='42',title='Second',finishReading=1,secret=1)],
                archive=[dict(archiveId='7',name='Original group',bookIds=['41'])])


def plan():
    old=dict(owner='900000',book_id='99',members_sha256=members_digest(['41','42']),
             grant_sha256=hashlib.sha256(canonical(credentials())).hexdigest())
    return bind(old,source())


class ModelTests(unittest.TestCase):
    def test_exact_original_members_flags_and_groups_survive_add_and_remove(self):
        value=source();p=plan();self.assertTrue(check(p,value,False))
        value['books'].append(dict(bookId='99',title='Only new book',finishReading=0))
        self.assertTrue(check(p,value,True))
        value['books'].reverse();value['books'][0]['readUpdateTime']=42
        self.assertTrue(check(p,value,True),'observational ordering/time became an unrelated flag')
        with self.assertRaises(ValueError):check(p,value,False)

    def test_original_flag_group_member_and_label_changes_are_refused(self):
        for kind in ('flag','member','group','label'):
            value=source()
            if kind=='flag':value['books'][0]['secret']=1
            elif kind=='member':value['books'].pop()
            elif kind=='group':value['archive'][0]['bookIds'].append('42')
            else:value['archive'][0]['name']='Changed'
            with self.subTest(kind=kind),self.assertRaises(ValueError):check(plan(),value,False)

    def test_preexisting_target_unknown_flags_duplicate_and_malformed_plans_refused(self):
        for kind in ('present','invalid','duplicate'):
            value=source()
            if kind=='present':value['books'].append(dict(bookId='99',title='Preexisting'))
            elif kind=='invalid':value['books'][0]['finishReading']='bad'
            else:value['books'].append(value['books'][0])
            with self.subTest(kind=kind),self.assertRaises(ValueError):bind(plan()['membership'],value)
        for value in (dict(plan(),extra=True),dict(plan(),protocol='old'),dict(plan(),flags_sha256=True)):
            with self.assertRaises(ValueError):validate_plan(value)


class StoreTests(unittest.TestCase):
    def test_two_slots_reserved_once_across_reopen_and_not_prototype_scope(self):
        backend=Backend();store=NativeShelfTrialStore(backend);r=store.reserve(plan())
        self.assertTrue(store.owns(r,plan()));self.assertTrue(NativeShelfTrialStore(backend).pending())
        self.assertEqual(store.read()[0]['reserved_posts'],2)
        with self.assertRaises(StoreError):NativeShelfTrialStore(backend).reserve(plan())
        self.assertNotIn('900000',repr(r))

    def test_proof_ownership_and_readback_are_required(self):
        backend=Backend();store=NativeShelfTrialStore(backend);r=store.reserve(plan())
        with self.assertRaises(StoreError):store.finish(r)
        store.finish(r,restored_verified=True);new=store.reserve(plan())
        with self.assertRaises(StoreError):store.finish(r,restored_verified=True)
        self.assertTrue(store.owns(new,plan()))
        backend.delete=lambda:None
        with self.assertRaises(StoreError):store.finish(new,restored_verified=True)

    def test_corruption_and_failed_save_remain_blocked(self):
        for raw in (b'invalid',b'[]',b'null'):
            backend=Backend();backend.data=raw;store=NativeShelfTrialStore(backend)
            with self.assertRaises(StoreError):store.reserve(plan())
            self.assertEqual(backend.data,raw)
        backend=Backend();backend.load=lambda:None
        with self.assertRaises(StoreError):NativeShelfTrialStore(backend).reserve(plan())


class RunnerTests(unittest.TestCase):
    def fixture(self):
        store=NativeShelfTrialStore(Backend());probe=task.ShelfTrialProbe()
        probe.bound=plan();probe.payload=dict(credentials=credentials(),book_id='99',shelf_books=2,
            expected_metadata=dict(bookId='99',title='Synthetic'),members_digest=plan()['membership']['members_sha256'])
        probe.read=Mock(return_value=True)
        child=Mock(stdin=io.BytesIO(),stdout=io.BytesIO());child.wait.return_value=0;child.poll.return_value=0
        return probe,store,child

    def execute(self,*,armed=True,events=None,read_failure=False,bad_receipt=False):
        probe,store,child=self.fixture()
        if read_failure:probe.read.side_effect=[True,ValueError('host conflict')];child.poll.return_value=None
        sequence=list(events if events is not None else ([dict(seq=1),dict(seq=2)] if armed else []))
        def frame():
            if sequence:return 'STEP',sequence.pop(0)
            r=store.read()[1]
            value=dict(runner=dict(report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,runner_error='none',stage=stage(armed)),
                private=dict(plan_fingerprint='a'*64 if bad_receipt else fingerprint(probe.bound['membership']),
                    intent_digest=hashlib.sha256(r.pending).hexdigest() if r else '',
                    final_members_digest=probe.bound['membership']['members_sha256'])),installed=dict(files=250,bytes_match=True))
            value['runner']['report']['stage']['shelf_books']=2
            return 'RESULT',value
        with patch.object(task.subprocess,'Popen',return_value=child),patch.object(task,'Frames') as frames,patch.object(task,'stop'):
            frames.return_value.next.side_effect=frame
            try:result=task.run(probe,credentials(),store,['synthetic-native'],armed=armed)
            except task.TrialFailure as error:result=error
        return result,probe,store,child

    def test_each_native_step_waits_for_full_independent_read_and_final_restore(self):
        result,probe,store,child=self.execute()
        self.assertEqual(result['account_data_posts'],2);self.assertEqual(result['independent_steps'],2)
        self.assertEqual([call.args[1] for call in probe.read.call_args_list],[False,True,False,False])
        self.assertFalse(store.pending());raw=child.stdin.getvalue()
        self.assertIn(b'"seq":1,"ok":true',raw);self.assertIn(b'"seq":2,"ok":true',raw)

    def test_dry_run_reserves_nothing_and_reads_original_state_twice(self):
        result,probe,store,_child=self.execute(armed=False)
        self.assertEqual(result['account_data_posts'],0);self.assertEqual(result['reserved_posts'],0)
        self.assertFalse(store.pending());self.assertEqual(probe.read.call_count,2)

    def test_bad_step_sequence_never_releases_a_second_post(self):
        for event in (dict(seq=2),dict(seq=True),dict(seq=1,extra=True)):
            result,_probe,store,child=self.execute(events=[event])
            self.assertIsInstance(result,task.TrialFailure);self.assertTrue(store.pending())
            self.assertNotIn(b'"ok":true',child.stdin.getvalue())

    def test_host_conflict_blocks_next_step_and_keeps_reservation(self):
        result,_probe,store,child=self.execute(read_failure=True)
        self.assertIsInstance(result,task.TrialFailure);self.assertTrue(store.pending())
        self.assertIn(b'"seq":1,"ok":false',child.stdin.getvalue())
        self.assertNotIn(b'"seq":1,"ok":true',child.stdin.getvalue())

    def test_foreign_receipt_cannot_clear_successful_native_counts(self):
        result,_probe,store,_child=self.execute(bad_receipt=True)
        self.assertIsInstance(result,task.TrialFailure);self.assertTrue(store.pending())

    def test_reserved_trial_cannot_launch_or_repeat_even_after_no_dispatch(self):
        probe,store,_child=self.fixture();store.reserve(plan())
        with patch.object(task.subprocess,'Popen') as launch,self.assertRaises(ValueError):task.run(probe,credentials(),store,['native'],armed=True)
        launch.assert_not_called();probe.read.assert_not_called()

    def test_same_owner_replaced_grant_prevents_launch(self):
        probe,store,_child=self.fixture()
        with patch.object(task.subprocess,'Popen') as launch,self.assertRaises(ValueError):
            task.run(probe,dict(credentials(),accessToken='changed'),store,['native'],armed=True)
        launch.assert_not_called();self.assertFalse(store.pending())

    def test_installation_mismatch_is_not_a_success(self):
        with self.assertRaises(ValueError):task.validate_result(dict(runner={},installed=dict(files=250,bytes_match=False)),True)


class RecoveryTests(unittest.TestCase):
    def test_readonly_recovery_requires_two_independent_restored_projections(self):
        store=NativeShelfTrialStore(Backend());store.reserve(plan());probe=Mock()
        probe.request.return_value=source();result=task.resolve(credentials(),store,probe)
        self.assertEqual(probe.request.call_count,2);self.assertEqual(result['account_data_posts'],0)
        self.assertFalse(result['prior_native_trial_success_claimed']);self.assertFalse(store.pending())

    def test_present_target_or_foreign_owner_cannot_be_silently_cleared(self):
        for owner in ('900000','900001'):
            store=NativeShelfTrialStore(Backend());store.reserve(plan());probe=Mock();value=source()
            value['books'].append(dict(bookId='99',title='New test book'));probe.request.return_value=value
            with self.assertRaises(ValueError):task.resolve(dict(credentials(),vid=owner),store,probe)
            self.assertTrue(store.pending())

    def test_other_trials_are_blocked_by_native_shelf_intent_unless_explicitly_excluded(self):
        import verify_native_thought_trial as shared
        with patch.object(shared,'AnnotationExperimentStore') as a,patch.object(shared,'FinishExperimentStore') as f,\
             patch.object(shared,'ShelfExperimentStore') as s,patch.object(shared,'PositionExperimentStore') as p,\
             patch.object(shared,'HighlightTrialStore') as h,patch.object(shared,'MarkStyleTrialStore') as style,\
             patch.object(shared,'BookmarkTrialStore') as bookmarks,patch.object(shared,'NativeShelfTrialStore') as native,patch.object(shared,'NativeFinishTrialStore') as finish,patch.object(shared,'InitialMarkStyleStore') as initial,patch.object(shared,'MarkColorStore') as colors,patch.object(shared,'NonemptyMarksStore') as nonempty:
            nonempty.return_value.read.return_value=initial.return_value.read.return_value=colors.return_value.read.return_value=(None,None)
            finish.return_value.pending.return_value=False
            for factory in (a,f,s,p):factory.return_value.pending.return_value=False
            for factory in (h,style,bookmarks):factory.return_value.read.return_value=(None,None)
            native.return_value.pending.return_value=True
            self.assertTrue(shared.other_pending());self.assertFalse(shared.other_pending(exclude_native_shelf=True))
            s.return_value.pending.return_value=True;self.assertTrue(shared.other_pending(exclude_native_shelf=True))

    def test_default_is_offline_without_account_or_keychain_access(self):
        with patch.object(task,'SessionStore') as login,patch.object(task,'NativeShelfTrialStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        login.assert_not_called();store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
