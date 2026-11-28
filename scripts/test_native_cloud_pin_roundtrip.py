import copy
import io
import unittest
from unittest.mock import Mock,patch
from native_cloud_pin_roundtrip import RoundtripFailure,native_child,run
from secure_native_cloud_pin_trial import NativeCloudPinTrialStore
from secure_pin_trial import PinTrialStore
from test_pin_trial_contract import Fixture
from test_secure_pin_trial import Backend
from verify_pin_preflight import fingerprint,reading_fingerprint


class RoundtripTests(unittest.TestCase):
    def test_child_rejects_armed_base_command_and_boolean_sequence(self):
        with self.assertRaises(ValueError):native_child({},['synthetic','--armed'],armed=False,on_step=lambda _n:None)
        child=Mock(stdin=io.BytesIO(),stdout=io.BytesIO());child.poll.return_value=None;received=[]
        with patch('native_cloud_pin_roundtrip.subprocess.Popen',return_value=child),\
             patch('native_cloud_pin_roundtrip.Frames') as frames,patch('native_cloud_pin_roundtrip.write_initial'),\
             patch('native_cloud_pin_roundtrip.stop'),patch('native_cloud_pin_roundtrip.reply') as reply:
            frames.return_value.next.return_value=('STEP',{'seq':True})
            with self.assertRaises(RoundtripFailure):native_child({},['synthetic'],armed=True,on_step=received.append)
        self.assertEqual(received,[])
        self.assertFalse(any(call.args[1].get('ok') is True for call in reply.call_args_list))

    def fixture(self):
        f=Fixture(True);f.progress={'book':{'bookId':'42','chapterUid':2,'chapterIdx':2,'chapterOffset':0,'progress':0,'updateTime':100},'timestamp':1}
        credentials={'vid':'123','accessToken':'synthetic-access'}
        for plan in f.plan.values():plan['membership']['grant_sha256']=fingerprint(credentials)
        f.credentials=credentials;f.reading_sha=reading_fingerprint(f.progress);f.inner=NativeCloudPinTrialStore(Backend());f.native_posts=0
        f.metadata={'bookId':'42','title':'Synthetic target'}
        def send(op):
            result=f.write(op);f.progress['book']['updateTime']+=1;return result
        f.send=send
        return f
    def execute(self,f,child):
        with patch('native_cloud_pin_roundtrip.native_child',side_effect=child):
            return run(f.plan,f.reading_sha,'c'*64,f.store,f.inner,f.current,f.read,f.send,['synthetic'],f.credentials,f.metadata)
    def good_child(self,f):
        def child(_payload,_command,*,armed,on_step):
            if not armed:return {'result':'PASS'},0
            f.pinned=True;f.native_posts+=1;on_step(1)
            f.pinned=False;f.native_posts+=1;on_step(2)
            return {'result':'PASS'},2
        return child
    def test_full_sequence_preserves_reading_and_consumes_both_intents(self):
        f=self.fixture();result=self.execute(f,self.good_child(f))
        self.assertEqual(result['result'],'OWNER_NATIVE_PIN_ROUNDTRIP_VERIFIED')
        self.assertEqual(f.writes,['add','remove']);self.assertEqual(f.native_posts,2);self.assertEqual(result['independent_steps'],2)
        self.assertFalse(result['book_update_time_unchanged']);self.assertTrue(result['original_shelf_and_reading_fields_verified'])
        self.assertEqual(f.store.read()[0]['phase'],'restored');self.assertEqual(f.inner.read()[0]['phase'],'retired')
        with self.assertRaises(ValueError):self.execute(f,self.good_child(f))
    def test_unknown_add_receipt_never_starts_native_or_removes(self):
        f=self.fixture();f.send=lambda op:(f.writes.append(op) or {})
        with self.assertRaises(RoundtripFailure) as error:self.execute(f,self.good_child(f))
        self.assertEqual(error.exception.phase,'add_pending');self.assertEqual(f.writes,['add']);self.assertEqual(f.native_posts,0)
        self.assertIsNone(f.inner.read()[0]);self.assertTrue(f.store.pending())
    def test_dry_run_failure_cannot_start_native_or_remove(self):
        f=self.fixture()
        def child(*_args,**_kwargs):raise ValueError('synthetic')
        with self.assertRaises(RoundtripFailure) as error:self.execute(f,child)
        self.assertEqual(error.exception.phase,'add_verified');self.assertEqual(f.writes,['add']);self.assertEqual(f.native_posts,0)
        self.assertIsNone(f.inner.read()[0])
    def test_unobserved_pin_or_other_change_blocks_unpin(self):
        for kind in ('missing_pin','unrelated'):
            f=self.fixture()
            def child(_payload,_command,*,armed,on_step):
                if not armed:return {'result':'PASS'},0
                f.native_posts+=1
                if kind=='unrelated':f.pinned=True;f.bad='unrelated'
                on_step(1);raise AssertionError('unexpected continuation')
            with self.subTest(kind=kind),self.assertRaises(RoundtripFailure) as error:self.execute(f,child)
            self.assertEqual(error.exception.phase,'pin_pending');self.assertEqual(f.writes,['add']);self.assertEqual(f.native_posts,1)
            self.assertTrue(f.inner.pending());self.assertTrue(f.store.pending())
    def test_unconfirmed_unpin_never_removes_test_book(self):
        f=self.fixture()
        def child(_payload,_command,*,armed,on_step):
            if not armed:return {'result':'PASS'},0
            f.pinned=True;f.native_posts+=1;on_step(1);f.native_posts+=1;on_step(2)
            raise AssertionError('unexpected continuation')
        with self.assertRaises(RoundtripFailure) as error:self.execute(f,child)
        self.assertEqual(error.exception.phase,'unpin_pending');self.assertEqual(f.writes,['add']);self.assertTrue(f.inner.pending())
    def test_changed_reading_before_reservation_or_grant_mismatch_blocks_writes(self):
        f=self.fixture();f.progress['book']['chapterOffset']=1
        with self.assertRaises(ValueError):self.execute(f,self.good_child(f))
        self.assertEqual(f.writes,[]);self.assertIsNone(f.store.read()[0])
        f=self.fixture();f.credentials['vid']='999'
        with self.assertRaises(ValueError):self.execute(f,self.good_child(f))
        self.assertEqual(f.writes,[]);self.assertIsNone(f.store.read()[0])


if __name__=='__main__':unittest.main()
