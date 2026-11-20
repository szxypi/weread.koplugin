"""Offline contracts for an isolated, single synthetic import trial."""
from copy import deepcopy
import contextlib,io,json,unittest
from unittest.mock import patch
from personal_upload_trial import Journal,check,hash_value,prepare,projection,validate
from secure_weread_session import StoreError
from test_native_shelf_trial import source
from test_secure_native_session import Backend,credentials
from verify_personal_upload_trial import BODY as EXEC_BODY,Probe,acknowledged,main,run

NAME='KOReaderSynthetic-0123456789abcdef.txt';BODY=b'Unique synthetic reading fixture.\n';TARGET='CB_synthetic123'


class TrialTest(unittest.TestCase):
    def test_only_new_target_may_be_added_and_removed(self):
        value=source();plan=prepare(credentials(),value,NAME,BODY);self.assertTrue(check(plan,credentials(),value))
        value['books'].append(dict(bookId=TARGET,title='Synthetic import',finishReading=0))
        self.assertTrue(check(plan,credentials(),value,TARGET,True))
        for kind in ('flag','member','group','grant','wrong_target'):
            candidate=deepcopy(value);grant=credentials();target=TARGET
            if kind=='flag':candidate['books'][0]['secret']=1
            elif kind=='member':candidate['books'].append(dict(bookId='99',title='Other'))
            elif kind=='group':candidate['archive'][0]['bookIds'].append('42')
            elif kind=='grant':grant['accessToken']='synthetic-other'
            else:target='CB_other'
            with self.subTest(kind=kind),self.assertRaises(ValueError):check(plan,grant,candidate,target,True)
        value['books'].pop();self.assertTrue(check(plan,credentials(),value,TARGET,False))

    def test_scope_and_source_are_strict(self):
        plan=prepare(credentials(),source(),NAME,BODY)
        for value in (dict(plan,extra=True),dict(plan,name='other.txt'),dict(plan,count=True),dict(plan,body_sha256='bad')):
            with self.subTest(value=value),self.assertRaises(ValueError):validate(value)
        for bad in ('','0','MP_WXS_42','../outside','CB_a/b'):
            with self.subTest(bad=bad),self.assertRaises(ValueError):projection(source(),bad)
        with self.assertRaises(ValueError):prepare(credentials(),source(),NAME,b'')

    def test_durable_journal_rejects_replays_and_wrong_steps(self):
        journal=Journal(Backend());receipt=journal.reserve(prepare(credentials(),source(),NAME,BODY))
        with self.assertRaises(StoreError):journal.reserve(prepare(credentials(),source(),NAME,BODY))
        with self.assertRaises(StoreError):journal.advance(receipt,'upload_pending')
        old=receipt;receipt=journal.advance(receipt,'credential_pending')
        with self.assertRaises(StoreError):journal.advance(old,'credential_pending')
        with self.assertRaises(StoreError):journal.advance(receipt,'credential_ready')
        receipt=journal.advance(receipt,'credential_ready',object_sha256='a'*64)
        for phase in ('upload_pending','uploaded','notify_pending'):receipt=journal.advance(receipt,phase)
        with self.assertRaises(StoreError):journal.advance(receipt,'imported',target='MP_WXS_42')
        receipt=journal.advance(receipt,'imported',target=TARGET)
        for phase in ('cleanup_pending','restored'):receipt=journal.advance(receipt,phase)
        self.assertEqual(journal.read()[0]['phase'],'restored')
        with self.assertRaises(StoreError):journal.advance(receipt,'credential_pending')
        self.assertNotIn(TARGET,repr(receipt))

    def test_corrupt_intent_fails_closed(self):
        backend=Backend();backend.save(b'{"schema":true}')
        with self.assertRaises(StoreError):Journal(backend).read()
        with self.assertRaises(StoreError):Journal(backend).reserve(prepare(credentials(),source(),NAME,BODY))


def temporary():return dict(bucket='synthetic-12345',ObjectName='/prefix/synthetic-book',Response=dict(ExpiredTime=1300,
    Credentials=dict(TmpSecretId='synthetic-id',TmpSecretKey='synthetic-key',Token='synthetic-token')))


class FakeProbe:
    def __init__(self,mode='normal'):
        self.state=source();self.mode=mode;self.attempts=dict(credential=0,put=0,notify=0,cleanup=0);self.reads=0
    def shelf(self,_grant):
        self.reads+=1;value=deepcopy(self.state)
        if self.mode=='baseline_changed' and self.reads==2:value['books'][0]['secret']=1
        if self.mode=='foreign_change' and self.attempts['notify']:value['books'][0]['secret']=1
        return value
    def credential(self,_grant,_receipt):
        self.attempts['credential']+=1
        if self.mode=='credential_lost':raise TimeoutError()
        return temporary()
    def put(self,_grant,_receipt,_temporary,_body,_now):
        self.attempts['put']+=1
        if self.mode=='put_lost':raise TimeoutError()
        return True
    def notify(self,_grant,_receipt,_temporary):
        self.attempts['notify']+=1
        if self.mode=='notify_lost':raise TimeoutError()
        if self.mode=='notify_invalid':return {'status':1,'bookId':TARGET,'errCode':-1}
        target='41' if self.mode=='existing_target' else TARGET
        if target!= '41':self.state['books'].append(dict(bookId=target,title='Synthetic',finishReading=0))
        return {'status':1,'bookId':target}
    def cleanup(self,_grant,_receipt):
        self.attempts['cleanup']+=1;self.state['books']=[b for b in self.state['books'] if b['bookId']!=TARGET]
        if self.mode=='cleanup_lost':raise TimeoutError()
        return {} if self.mode=='cleanup_bad_ack' else {'succ':1}


class ExecutionTest(unittest.TestCase):
    def test_verified_roundtrip_is_exactly_once_and_cannot_replay(self):
        probe=FakeProbe();journal=Journal(Backend());grant=credentials()
        result=run(probe,journal,grant,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000)
        self.assertEqual(result['result'],'SYNTHETIC_IMPORT_ROUNDTRIP_VERIFIED')
        self.assertEqual(probe.attempts,dict(credential=1,put=1,notify=1,cleanup=1))
        self.assertEqual(journal.read()[0]['phase'],'restored')
        self.assertEqual(run(probe,journal,grant,lambda _:True,apply=True,now=lambda:1000)['reason'],'personal_upload/already_reserved')
        self.assertEqual(probe.attempts,dict(credential=1,put=1,notify=1,cleanup=1))

    def test_unknown_or_foreign_outcomes_stop_before_next_mutation(self):
        for mode,phase,counts in (
            ('baseline_changed',None,(0,0,0,0)),('credential_lost','credential_pending',(1,0,0,0)),
            ('put_lost','upload_pending',(1,1,0,0)),('notify_lost','notify_pending',(1,1,1,0)),
            ('notify_invalid','notify_pending',(1,1,1,0)),('existing_target','notify_pending',(1,1,1,0)),
            ('foreign_change','notify_pending',(1,1,1,0)),('cleanup_lost','cleanup_pending',(1,1,1,1)),
            ('cleanup_bad_ack','cleanup_pending',(1,1,1,1))):
            with self.subTest(mode=mode):
                probe=FakeProbe(mode);journal=Journal(Backend())
                result=run(probe,journal,credentials(),lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000)
                self.assertEqual(result['result'],'UNVERIFIED')
                self.assertEqual(tuple(probe.attempts.values()),counts)
                state=journal.read()[0];self.assertEqual(state['phase'] if state else None,phase)

    def test_preview_is_read_only_and_receipts_are_strict(self):
        journal=Journal(Backend());probe=FakeProbe()
        self.assertEqual(run(probe,journal,credentials(),lambda _:True,now=lambda:1000)['result'],'READ_ONLY_PREVIEW')
        self.assertIsNone(journal.read()[0]);self.assertFalse(any(probe.attempts.values()))
        for value in ({},{'succ':0,'success':True},{'succ':1,'errCode':False},{'succ':1,'success':False}):self.assertFalse(acknowledged(value))
        with patch('verify_personal_upload_trial.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0);store.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_transport_rejects_foreign_or_replayed_upload(self):
        class Response:
            status=200
            def __enter__(self):return self
            def __exit__(self,*_args):return False
            def read(self,_limit):return b''
        class Opener:
            def __init__(self):self.requests=[]
            def open(self,request,timeout):self.requests.append(request);return Response()
        grant=credentials();journal=Journal(Backend());plan=prepare(grant,source(),NAME,EXEC_BODY);receipt=journal.reserve(plan)
        cos=Opener();probe=Probe(journal,lambda _:True,cos_opener=cos)
        with self.assertRaises(ValueError):probe.put(grant,receipt,temporary(),EXEC_BODY,1000)
        receipt=journal.advance(receipt,'credential_pending')
        receipt=journal.advance(receipt,'credential_ready',object_sha256=hash_value({'bucket':temporary()['bucket'],'ObjectName':temporary()['ObjectName']}))
        receipt=journal.advance(receipt,'upload_pending')
        with self.assertRaises(ValueError):probe.put(grant,receipt,temporary(),b'different',1000)
        self.assertTrue(probe.put(grant,receipt,temporary(),EXEC_BODY,1000))
        with self.assertRaises(ValueError):probe.put(grant,receipt,temporary(),EXEC_BODY,1000)
        self.assertEqual(len(cos.requests),1);self.assertEqual(cos.requests[0].get_method(),'PUT')
        self.assertNotIn('Cookie',dict(cos.requests[0].header_items()))


if __name__=='__main__':unittest.main()
