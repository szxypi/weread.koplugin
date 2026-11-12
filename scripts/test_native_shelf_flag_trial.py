"""Private-reading native transport, binding, host barriers and tombstones."""
from contextlib import ExitStack,redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
import unittest
from unittest.mock import Mock,patch
from native_shelf_flag_trial import bind,check,validate_plan
from secure_native_shelf_flag_trial import NativeFlagTrialStore
from secure_shelf_flag_trial import FlagTrialStore,SERVICE as PYTHON_TRIAL_SERVICE
from secure_shelf_experiment import canonical
from secure_weread_session import StoreError
from test_secure_native_session import Backend,credentials
from test_shelf_flag_change import source,point
from test_native_finish_trial import stage
from run_native_shelf_flag_trial import validate_payload
import verify_native_finish_trial as bridge
import verify_native_shelf_flag_trial as task


def plan():return bind('900000','41',hashlib.sha256(canonical(credentials())).hexdigest(),source(),point())
def changed():
    value=source();value['books'][0]['secret']=1;return value


class NativePrivateTests(unittest.TestCase):
    def test_original_visibility_and_opposite_directions_are_bound(self):
        p=plan();self.assertTrue(check(p,source(),point(),False));self.assertTrue(check(p,changed(),point(),True))
        self.assertNotEqual(p['mark']['request_hash'],p['restore']['request_hash'])
        with self.assertRaises(ValueError):bind('900000','41','a'*64,changed(),point())
    def test_other_flags_groups_and_exact_position_cannot_be_ignored(self):
        for kind in ('finish','member','group','offset'):
            value=changed();progress=point()
            if kind=='finish':value['books'][1]['finishReading']=0
            elif kind=='member':value['books'].pop()
            elif kind=='group':value['archive'][0]['name']='Changed'
            else:progress['book']['chapterOffset']+=1
            with self.subTest(kind=kind),self.assertRaises(ValueError):check(plan(),value,progress,True)
    def test_malformed_or_wider_protocol_is_rejected(self):
        for mutate in (lambda p:p.update(extra=1),lambda p:p['mark'].update(kind='pinned'),lambda p:p['restore'].update(book_id='42'),
                       lambda p:p['restore'].update(position_hash='f'*64),lambda p:p['mark'].update(desired=1)):
            value=plan();mutate(value)
            with self.assertRaises(ValueError):validate_plan(value)
    def test_new_scope_is_not_the_consumed_python_intent(self):
        backend=Backend();store=NativeFlagTrialStore(backend);receipt=store.reserve(plan())
        self.assertTrue(store.pending());self.assertTrue(store.owns(receipt,plan()))
        self.assertNotEqual(store.service,PYTHON_TRIAL_SERVICE)
        with self.assertRaises(StoreError):FlagTrialStore(backend).read()
        with self.assertRaises(StoreError):store.reserve(plan())
    def test_completed_tombstone_survives_reopen_and_blocks_replay(self):
        backend=Backend();store=NativeFlagTrialStore(backend);receipt=store.reserve(plan())
        with self.assertRaises(StoreError):store.finish(receipt)
        store.finish(receipt,restored_verified=True);reopened=NativeFlagTrialStore(backend)
        self.assertFalse(reopened.pending());self.assertEqual(reopened.read()[0]['phase'],'retired')
        self.assertFalse(reopened.owns(receipt,plan()))
        with self.assertRaises(StoreError):reopened.reserve(plan())
        with self.assertRaises(StoreError):reopened.finish(receipt,restored_verified=True)
    def test_unverified_storage_or_corruption_never_grants_dispatch(self):
        backend=Backend();store=NativeFlagTrialStore(backend);store.reserve(plan());backend.data=b'{}'
        with self.assertRaises(StoreError):store.pending()
        backend=Backend();backend.load=lambda:None
        with self.assertRaises(StoreError):NativeFlagTrialStore(backend).reserve(plan())
    def test_both_private_intents_block_all_existing_exclusion_modes(self):
        import verify_native_thought_trial as shared
        factories=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore','NativeShelfTrialStore',
            'NativeFinishTrialStore','FlagTrialStore','NativeFlagTrialStore','MarkStyleTrialStore','HighlightTrialStore','BookmarkTrialStore',
            'InitialMarkStyleStore','MarkColorStore','NonemptyMarksStore','ReadtimeTrialStore')
        with ExitStack() as stack:
            mocks={key:stack.enter_context(patch.object(shared,key)) for key in factories}
            for value in mocks.values():value.return_value.pending.return_value=False;value.return_value.read.return_value=(None,None)
            options=dict(exclude_native_highlight=True,exclude_bookmark=True,exclude_native_bookmark=True,exclude_native_shelf=True,exclude_native_finish=True,exclude_mark_color=True)
            self.assertFalse(shared.other_pending(**options))
            for name in ('FlagTrialStore','NativeFlagTrialStore'):
                mocks[name].return_value.pending.return_value=True;self.assertTrue(shared.other_pending(**options))
                mocks[name].return_value.pending.return_value=False
    def test_native_payload_is_exactly_bound(self):
        p=plan();value=dict(credentials=credentials(),book_id='41',expected_metadata=dict(bookId='41',title='Synthetic'),shelf_books=2,
            mark=p['mark'],restore=p['restore'],permit_writes=False,rpc_token='a'*32)
        validate_payload(value,False,None)
        for field,bad in (('permit_writes',True),('shelf_books',True),('book_id','42'),('mark',p['restore'])):
            with self.assertRaises(Exception):validate_payload(dict(value,**{field:bad}),False,None)
    def execute(self,armed=True,conflict=False):
        p=plan();probe=task.FlagTrialProbe();probe.bound=p;probe.read=Mock(return_value=True)
        probe.payload=dict(credentials=credentials(),book_id='41',expected_metadata=dict(bookId='41',title='Synthetic'),shelf_books=2,
            mark=p['mark'],restore=p['restore']);store=NativeFlagTrialStore(Backend())
        child=Mock(stdin=io.BytesIO(),stdout=io.BytesIO());child.wait.return_value=0;child.poll.return_value=0
        if conflict:probe.read.side_effect=[True,ValueError('changed')]
        events=[('STEP',dict(seq=1)),('STEP',dict(seq=2))] if armed else []
        events.append(('RESULT',dict(result='PASS',profile_removed=True,installed=dict(files=269,bytes_match=True),stage=stage(armed))))
        with patch.object(bridge.subprocess,'Popen',return_value=child),patch.object(bridge,'Frames') as frames,patch.object(bridge,'stop'):
            frames.return_value.next.side_effect=events
            try:result=task.run(probe,credentials(),store,['synthetic-native'],armed=armed)
            except task.TrialFailure as error:result=error
        return result,probe,store,child
    def test_two_independent_host_barriers_precede_restoration_and_retirement(self):
        result,probe,store,child=self.execute();self.assertEqual(result['intent_state'],'retired')
        self.assertEqual([call.args[1] for call in probe.read.call_args_list],[False,True,False,False])
        self.assertFalse(store.pending());self.assertEqual(store.read()[0]['reserved_posts'],2)
        self.assertIn(b'"seq":1,"ok":true',child.stdin.getvalue());self.assertIn(b'"seq":2,"ok":true',child.stdin.getvalue())
    def test_failed_independent_check_stops_restoration_and_preserves_intent(self):
        result,_probe,store,child=self.execute(conflict=True);self.assertIsInstance(result,task.TrialFailure)
        self.assertTrue(store.pending());self.assertNotIn(b'"seq":1,"ok":true',child.stdin.getvalue())
    def test_dry_run_reserves_nothing(self):
        result,probe,store,_child=self.execute(armed=False);self.assertEqual(result['account_data_posts'],0)
        self.assertEqual(probe.read.call_count,2);self.assertEqual(store.read(),(None,None))
    def test_host_cannot_send_private_or_unrelated_posts(self):
        probe=task.FlagTrialProbe();probe.targets={'41'}
        for path in ('book/secret','shelf/top','login'):
            with self.assertRaises(ValueError):probe.request('write','https://i.weread.qq.com/'+path,{},credentials())
    def test_offline_default_does_not_load_credentials(self):
        with patch.object(task,'SessionStore') as login,patch.object(task,'NativeFlagTrialStore') as store,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        login.assert_not_called();store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
