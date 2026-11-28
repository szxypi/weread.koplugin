"""Offline contracts for the separate, non-replayable subscription trial."""
from copy import deepcopy
import contextlib,io,json,unittest
from unittest.mock import patch
from mp_subscription_trial import Journal,prepare,check,projection,validate
from secure_weread_session import StoreError
from test_secure_native_session import Backend,credentials
from test_native_shelf_trial import source
from verify_eink_login import BASE
from verify_mp_subscription_trial import Probe,acknowledged,main,run

TARGET='MP_WXS_99999'


class ContractTest(unittest.TestCase):
    def test_only_exact_target_can_change(self):
        before=source();plan=prepare(credentials(),before,TARGET)
        self.assertTrue(check(plan,credentials(),before,False))
        after=deepcopy(before);after['books'].append(dict(bookId=TARGET,title='Synthetic',finishReading=0))
        self.assertTrue(check(plan,credentials(),after,True))
        after['books'].reverse();after['books'][0]['readUpdateTime']=42
        self.assertTrue(check(plan,credentials(),after,True))
        for kind in ('missing','changed_flag','extra_member','changed_group','wrong_grant','wrong_presence'):
            value=deepcopy(after);grant=credentials();expected=True
            if kind=='missing':value['books']=[b for b in value['books'] if b['bookId']!=TARGET]
            elif kind=='changed_flag':next(b for b in value['books'] if b['bookId']=='41')['secret']=1
            elif kind=='extra_member':value['books'].append(dict(bookId='45',title='Other'))
            elif kind=='changed_group':value['archive'][0]['bookIds'].append('42')
            elif kind=='wrong_grant':grant['accessToken']='different-synthetic'
            else:expected=False
            with self.subTest(kind=kind),self.assertRaises(ValueError):check(plan,grant,value,expected)

    def test_refuses_present_target_and_invalid_source(self):
        value=source();value['books'].append(dict(bookId=TARGET,title='Already there'))
        with self.assertRaises(ValueError):prepare(credentials(),value,TARGET)
        for bad in ('42','MP_WXS_0','MP_WXS_42/extra','MP_WXS_'+'1'*21):
            with self.subTest(bad=bad),self.assertRaises(ValueError):projection(source(),bad)
        value=source();value['books'].append(value['books'][0])
        with self.assertRaises(Exception):prepare(credentials(),value,TARGET)
        value=source();value['books'][0]['finishReading']='unknown'
        with self.assertRaises(ValueError):prepare(credentials(),value,TARGET)

    def test_journal_reserves_once_and_advances_only_in_order(self):
        backend=Backend();journal=Journal(backend);plan=prepare(credentials(),source(),TARGET);receipt=journal.reserve(plan)
        self.assertNotIn(TARGET,repr(receipt))
        with self.assertRaises(StoreError):Journal(backend).reserve(plan)
        with self.assertRaises(StoreError):journal.advance(receipt,'remove_pending')
        prior=receipt;receipt=journal.advance(receipt,'add_pending')
        with self.assertRaises(StoreError):journal.advance(prior,'add_pending')
        with self.assertRaises(StoreError):journal.advance(receipt,'remove_pending')
        for phase in ('add_confirmed','remove_pending','restored'):receipt=journal.advance(receipt,phase)
        self.assertEqual(Journal(backend).read()[0]['phase'],'restored')
        with self.assertRaises(StoreError):journal.reserve(plan)
        with self.assertRaises(StoreError):journal.advance(receipt,'add_pending')


class FakeProbe:
    def __init__(self,mode='normal'):
        self.state=source();self.mode=mode;self.attempts={'add':0,'remove':0};self.reads=0
    def shelf(self,_credentials):
        self.reads+=1
        value=deepcopy(self.state)
        if self.mode=='baseline_changed' and self.reads==2:value['books'][0]['secret']=1
        if self.mode=='before_remove_changed' and self.attempts['add'] and self.reads>=5:value['books'][0]['secret']=1
        return value
    def send(self,stage,_credentials,_receipt):
        self.attempts[stage]+=1
        if stage=='add':self.state['books'].append(dict(bookId=TARGET,title='Synthetic',finishReading=0))
        else:self.state['books']=[b for b in self.state['books'] if b['bookId']!=TARGET]
        if self.mode==stage+'_lost':raise TimeoutError()
        return {} if self.mode==stage+'_bad_ack' else {'succ':1}


class ExecutionTest(unittest.TestCase):
    def test_roundtrip_and_permanent_no_replay(self):
        probe=FakeProbe();journal=Journal(Backend());creds=credentials()
        result=run(probe,journal,creds,TARGET,lambda _:True,apply=True,sleep=lambda _:None)
        self.assertEqual(result['result'],'ROUNDTRIP_VERIFIED');self.assertEqual(result['account_data_posts'],2)
        self.assertTrue(result['independent_restore_verified']);self.assertEqual(journal.read()[0]['phase'],'restored')
        repeated=run(probe,journal,creds,TARGET,lambda _:True,apply=True,sleep=lambda _:None)
        self.assertEqual(repeated['reason'],'mp_subscription/already_reserved');self.assertEqual(probe.attempts,{'add':1,'remove':1})

    def test_unknown_or_conflicting_state_never_sends_next_step(self):
        for mode,phase,posts in (('add_lost','add_pending',1),('add_bad_ack','add_pending',1),
                                 ('before_remove_changed','add_confirmed',1),('remove_lost','remove_pending',2),
                                 ('remove_bad_ack','remove_pending',2),('baseline_changed',None,0)):
            with self.subTest(mode=mode):
                probe=FakeProbe(mode);journal=Journal(Backend())
                result=run(probe,journal,credentials(),TARGET,lambda _:True,apply=True,sleep=lambda _:None)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(result['account_data_posts'],posts)
                saved=journal.read()[0];self.assertEqual(saved['phase'] if saved else None,phase)
                self.assertLessEqual(probe.attempts['add'],1);self.assertLessEqual(probe.attempts['remove'],1)

    def test_preview_never_reserves_or_posts_and_invalid_ack_is_rejected(self):
        journal=Journal(Backend());probe=FakeProbe()
        self.assertEqual(run(probe,journal,credentials(),TARGET,lambda _:True)['result'],'READ_ONLY_PREVIEW')
        self.assertIsNone(journal.read()[0]);self.assertEqual(sum(probe.attempts.values()),0)
        for value in ({},{'succ':0,'success':True},{'succ':1,'errcode':False},{'succ':1,'success':False},{'succ':'1'}):
            self.assertFalse(acknowledged(value))
        self.assertTrue(acknowledged({'succ':1,'errCode':0}))
        with patch('verify_mp_subscription_trial.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0);store.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_native_transport_requires_owned_phase_and_never_replays(self):
        class Response:
            status=200
            def __enter__(self):return self
            def __exit__(self,*_args):return False
            def read(self,_size):return b'{"succ":1}'
        class Opener:
            def __init__(self):self.requests=[]
            def open(self,request,timeout):self.requests.append(request);return Response()
        backend=Backend();journal=Journal(backend);plan=prepare(credentials(),source(),TARGET);receipt=journal.reserve(plan)
        opener=Opener();probe=Probe(TARGET,journal,lambda _:True,opener)
        with self.assertRaises(ValueError):probe.send('add',credentials(),receipt)
        with self.assertRaises(ValueError):probe.request('add',BASE+'/shelf/add',{'bookIds':[TARGET]},credentials())
        receipt=journal.advance(receipt,'add_pending')
        self.assertTrue(acknowledged(probe.send('add',credentials(),receipt)))
        self.assertEqual(json.loads(opener.requests[0].data),dict(bookIds=[TARGET],albumIds=[],archiveIds=[]))
        with self.assertRaises(ValueError):probe.send('add',credentials(),receipt)
        with self.assertRaises(ValueError):probe.send('remove',credentials(),receipt)
        self.assertEqual(len(opener.requests),1)

    def test_invalid_plan_or_journal_fails_closed(self):
        plan=prepare(credentials(),source(),TARGET)
        for value in (dict(plan,extra=True),dict(plan,account_id='42'),dict(plan,count=True),dict(plan,flags_sha256='x')):
            with self.subTest(value=value),self.assertRaises(ValueError):validate(value)
        backend=Backend();backend.save(b'{"schema":true}')
        with self.assertRaises(StoreError):Journal(backend).read()
        with self.assertRaises(StoreError):Journal(backend).reserve(plan)


if __name__=='__main__':unittest.main()
