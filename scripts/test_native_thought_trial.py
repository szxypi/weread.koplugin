"""Offline reservation, pipe framing and strict public output checks."""
from copy import deepcopy
import io
import json
import os
import unittest
from unittest.mock import patch,Mock,call

from annotation_experiment_model import fingerprint
from native_trial_pipe import Frames,read_initial,reply,stop,write_initial
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_weread_session import StoreError
import test_annotation_experiment as annotations
from test_secure_native_session import Backend,credentials
from verify_native_thought_trial import TrialFailure,make_payload,run,validate_runner
from run_native_thought_trial import FLAGS,COUNTS,validate_stage


class TrialTests(unittest.TestCase):
    def fixture(self):
        probe,_opener,plan,_store,_receipt=annotations.AnnotationTests().fixture()
        store=NativeThoughtTrialStore(Backend());receipt=store.prepare(plan.bound)
        return probe,plan,store,receipt

    def test_full_reservation_has_three_independent_steps_then_cleanup(self):
        _probe,plan,store,receipt=self.fixture()
        with self.assertRaises(StoreError):store.finish(receipt)
        pending=store.claim(receipt);self.assertEqual(store.read()[0]['reserved_posts'],3)
        self.assertNotIn(plan.bound['nonce'],repr(pending))
        for sequence in range(1,4):pending=store.verified_step(pending,sequence,'synthetic-created')
        done=store.complete(pending);store.finish(done);self.assertFalse(store.pending())

    def test_pending_reopen_never_reclaims_or_discards_even_zero_verified_steps(self):
        _probe,_plan,store,receipt=self.fixture();pending=store.claim(receipt)
        reopened=NativeThoughtTrialStore(store.backend)
        self.assertEqual(reopened.read()[0]['verified_steps'],0)
        for action in [lambda:reopened.claim(receipt),lambda:reopened.claim(pending),lambda:reopened.finish(pending,discard_prepared=True),lambda:reopened.finish(pending),lambda:reopened.complete(pending)]:
            with self.assertRaises(StoreError):action()
        pending=reopened.verified_step(pending,1,'synthetic-created')
        for step,target in [(1,'synthetic-created'),(3,'synthetic-created'),(2,'other')]:
            with self.assertRaises(StoreError):reopened.verified_step(pending,step,target)

    def test_cas_corruption_and_prepared_discard(self):
        _probe,_plan,store,receipt=self.fixture();raw=store.backend.data
        for field,bad in [('schema',True),('reserved_posts',3),('verified_steps',1),('created_id','x'),('phase','other'),('attempt','x'),('extra',0)]:
            value=json.loads(raw);value[field]=bad;store.backend.data=json.dumps(value).encode()
            with self.subTest(field=field),self.assertRaises(StoreError):store.pending()
        store.backend.data=raw
        from secure_native_thought_trial import Receipt
        with self.assertRaises(StoreError):store.claim(Receipt(raw+b' '))
        store.finish(receipt,discard_prepared=True);self.assertFalse(store.pending())

    def test_failed_durable_readback_never_returns_reservation(self):
        probe,plan,store,receipt=self.fixture();backend=Backend();backend.load=lambda:None
        with self.assertRaises(StoreError):NativeThoughtTrialStore(backend).prepare(plan.bound)
        payload=make_payload(probe,credentials(),False)
        self.assertEqual(payload['create_body']['isPrivate'],1);self.assertFalse(payload['permit_writes'])
        self.assertIn('existing-note',payload['original_ids'])
        with self.assertRaises(ValueError):make_payload(probe,dict(credentials(),vid='900001'),False,mock_port=5000)

    def test_initial_and_reply_frames_have_strict_limits(self):
        stream=io.BytesIO();write_initial(stream,{'unicode':'中文'});stream.seek(0)
        self.assertEqual(read_initial(stream),{'unicode':'中文'})
        for raw in [b'0\n',b'99999999\n',b'02\n{}',b'3\n{}',b'2\n[]']:
            with self.assertRaises(ValueError):read_initial(io.BytesIO(raw))
        with self.assertRaises(ValueError):reply(io.BytesIO(),{'oversize':'x'*16384})
        with self.assertRaises(ValueError):Frames(io.BytesIO(),'bad')

    def test_private_frames_ignore_logs_and_reject_forged_or_partial_data(self):
        token='a'*32;prefix='WEREAD_NATIVE_THOUGHT_'+token+'_'
        for value,expected in [('noise\n'+prefix+'STEP={"seq":0}\n',('STEP',{'seq':0})),(prefix+'OTHER={}\n',ValueError),(prefix+'STEP=[]\n',ValueError)]:
            read_fd,write_fd=os.pipe()
            with os.fdopen(read_fd,'rb',buffering=0) as reader,os.fdopen(write_fd,'wb',buffering=0) as writer:
                writer.write(value.encode());frames=Frames(reader,token,timeout=.1)
                if expected is ValueError:
                    with self.assertRaises(ValueError):frames.next()
                else:self.assertEqual(frames.next(),expected)
        read_fd,write_fd=os.pipe()
        with os.fdopen(read_fd,'rb',buffering=0) as reader,os.fdopen(write_fd,'wb',buffering=0):
            with self.assertRaises(TimeoutError):Frames(reader,token,timeout=.01).next()

    def test_mode_and_exact_intent_fail_before_process_or_reservation(self):
        probe,plan,store,receipt=self.fixture()
        for expected in [None,'a'*64]:
            with patch('verify_native_thought_trial.subprocess.Popen') as spawn,self.assertRaises(ValueError):
                run(probe,credentials(),store,receipt,['false'],armed=True,expected=expected)
            spawn.assert_not_called();self.assertEqual(store.read()[0]['phase'],'prepared')

    def test_public_stage_schema_does_not_accept_private_or_invented_results(self):
        value=dict.fromkeys(FLAGS,True);value.update(dict.fromkeys(COUNTS,0));value.update(result='PASS',phase='complete',permit_writes=False,cache_verified=False,requests=9)
        validate_stage(value,False)
        runner=dict(result='PASS',profile_removed=True,installed_bytes_match=True,installed_files=227,stage=value)
        validate_runner(runner,False)
        for change in [('private','content'),('requests',True),('posts',1),('dispatch_blocked',False)]:
            bad=deepcopy(value);bad[change[0]]=change[1]
            with self.assertRaises(ValueError):validate_stage(bad,False)

    def success_runner(self,armed):
        stage=dict.fromkeys(FLAGS,True);stage.update(dict.fromkeys(COUNTS,0))
        stage.update(result='PASS',phase='complete',permit_writes=armed,cache_verified=armed,requests=16 if armed else 9,
            local_pending_kept=not armed,dispatch_blocked=not armed,posts=3 if armed else 0,steps=3 if armed else 0)
        return dict(result='PASS',profile_removed=True,installed_bytes_match=True,installed_files=227,stage=stage)

    def test_coordinator_reserves_before_launch_and_confirms_each_step_before_reply(self):
        probe,plan,store,receipt=self.fixture();probe.observe=Mock(return_value=plan.baseline)
        probe.readback=Mock(side_effect=[{'reviewId':'synthetic-created'},{'reviewId':'synthetic-created'},None])
        messages=[('STEP',dict(seq=sequence,created_id='synthetic-created')) for sequence in (1,2,3)]+[('RESULT',self.success_runner(True))]
        def spawn(*_args,**_kwargs):
            self.assertEqual(store.read()[0]['phase'],'pending');self.assertEqual(store.read()[0]['reserved_posts'],3)
            return Mock()
        def respond(_stream,value):
            self.assertEqual(store.read()[0]['verified_steps'],value['seq'])
        with patch('verify_native_thought_trial.subprocess.Popen',side_effect=spawn) as process,\
                patch('verify_native_thought_trial.Frames') as frames,patch('verify_native_thought_trial.write_initial'),\
                patch('verify_native_thought_trial.reply',side_effect=respond) as replies,patch('verify_native_thought_trial.stop'):
            child=Mock();child.wait.return_value=0;process.side_effect=lambda *_args,**_kwargs:(spawn(),child)[1]
            frames.return_value.next.side_effect=messages
            result=run(probe,credentials(),store,receipt,['synthetic-command'],armed=True,expected=fingerprint(plan.bound))
        self.assertEqual(result['independent_steps'],3);self.assertFalse(store.pending());self.assertEqual(replies.call_count,3)
        self.assertEqual(probe.readback.call_args_list,[call(credentials(),'created',edited=False),call(credentials(),'edited',edited=True),call(credentials(),'deleted',edited=False)])

    def test_independent_mismatch_or_bad_step_refuses_next_operation_and_keeps_reservation(self):
        for mode in ('readback','step','existing-target','runner'):
            probe,plan,store,receipt=self.fixture();probe.observe=Mock(return_value=plan.baseline)
            probe.readback=Mock(side_effect=ValueError('synthetic mismatch'))
            target='existing-note' if mode=='existing-target' else 'synthetic-created'
            step=dict(seq=2 if mode=='step' else 1,created_id=target)
            messages=[('RESULT',dict(self.success_runner(True),result='UNVERIFIED'))] if mode=='runner' else [('STEP',step),('RESULT',dict(self.success_runner(True),result='UNVERIFIED'))]
            with patch('verify_native_thought_trial.subprocess.Popen') as process,patch('verify_native_thought_trial.Frames') as frames,\
                    patch('verify_native_thought_trial.write_initial'),patch('verify_native_thought_trial.reply') as replies,patch('verify_native_thought_trial.stop'):
                process.return_value.poll.return_value=None;process.return_value.wait.return_value=1
                frames.return_value.next.side_effect=messages
                with self.subTest(mode=mode),self.assertRaises(TrialFailure):run(probe,credentials(),store,receipt,['synthetic-command'],armed=True,expected=fingerprint(plan.bound))
            state,_current=store.read();self.assertEqual((state['phase'],state['reserved_posts'],state['verified_steps']),('pending',3,0))
            self.assertTrue(all(item.args[1]['ok'] is False for item in replies.call_args_list))

    def test_process_launch_failure_consumes_all_slots_and_cannot_restart(self):
        probe,plan,store,receipt=self.fixture();probe.observe=Mock(return_value=plan.baseline)
        with patch('verify_native_thought_trial.subprocess.Popen',side_effect=OSError('synthetic startup')) as spawn:
            with self.assertRaises(TrialFailure):run(probe,credentials(),store,receipt,['synthetic-command'],armed=True,expected=fingerprint(plan.bound))
        self.assertEqual(store.read()[0]['reserved_posts'],3);pending,_current=store.read()
        with patch('verify_native_thought_trial.subprocess.Popen') as spawn,self.assertRaises(ValueError):
            run(probe,credentials(),store,store.read()[1],['synthetic-command'],armed=True,expected=fingerprint(pending['plan']))
        spawn.assert_not_called()

    def test_dry_run_matches_actual_body_and_retains_prepared_intent(self):
        probe,plan,store,receipt=self.fixture();probe.observe=Mock(return_value=plan.baseline)
        body=make_payload(probe,credentials(),False)['create_body']
        with patch('verify_native_thought_trial.subprocess.Popen') as process,patch('verify_native_thought_trial.Frames') as frames,\
                patch('verify_native_thought_trial.write_initial'),patch('verify_native_thought_trial.reply'),patch('verify_native_thought_trial.stop'):
            process.return_value.wait.return_value=0;frames.return_value.next.side_effect=[('STEP',dict(seq=0,preview=body)),('RESULT',self.success_runner(False))]
            result=run(probe,credentials(),store,receipt,['synthetic-command'],expected=fingerprint(plan.bound))
        self.assertEqual(result['reserved_posts'],0);self.assertEqual(store.read()[1],receipt)

    def test_default_does_not_access_credentials_or_network(self):
        from verify_native_thought_trial import main
        from contextlib import redirect_stdout
        with patch('verify_native_thought_trial.NativeSessionStore') as auth,patch('verify_native_thought_trial.NativeThoughtTrialStore') as intent,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0)
        auth.assert_not_called();intent.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE')


if __name__=='__main__':unittest.main()
