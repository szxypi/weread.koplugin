"""Offline checks for the separate native-upload trial's durable boundary."""
from copy import deepcopy
import contextlib,io,json,unittest
from unittest.mock import patch
from native_personal_upload_trial import Journal
from personal_upload_trial import prepare
from secure_weread_session import StoreError
from test_native_shelf_trial import source
from test_secure_native_session import Backend,credentials
from verify_native_personal_upload_trial import Probe,main,native_run,run


class NativeUploadJournalTest(unittest.TestCase):
    def test_single_trial_rejects_replay_stale_steps_and_other_targets(self):
        journal=Journal(Backend());plan=prepare(credentials(),source(),'KOReaderSynthetic-0123456789abcdef.txt',b'synthetic')
        reserved=journal.reserve(plan)
        with self.assertRaises(StoreError):journal.reserve(plan)
        with self.assertRaises(StoreError):journal.advance(reserved,'imported',target='CB_synthetic')
        launched=journal.advance(reserved,'launched')
        with self.assertRaises(StoreError):journal.advance(reserved,'launched')
        with self.assertRaises(StoreError):journal.advance(launched,'imported',target='MP_WXS_42')
        imported=journal.advance(launched,'imported',target='CB_synthetic')
        cleanup=journal.advance(imported,'cleanup_pending');done=journal.advance(cleanup,'restored')
        self.assertEqual(journal.read()[0]['phase'],'restored')
        with self.assertRaises(StoreError):journal.advance(done,'launched')
        self.assertNotIn('CB_synthetic',repr(done))
    def test_corrupt_intent_cannot_be_overwritten(self):
        backend=Backend();backend.save(b'{"schema":true}')
        with self.assertRaises(StoreError):Journal(backend).read()
        with self.assertRaises(StoreError):Journal(backend).reserve(prepare(credentials(),source(),'KOReaderSynthetic-0123456789abcdef.txt',b'x'))


class FakeProbe:
    def __init__(self,mode='normal'):
        self.state=source();self.mode=mode;self.cleanups=0;self.reads=0;self.spawns=0
    def shelf(self,_credentials):
        self.reads+=1;value=deepcopy(self.state)
        if self.mode=='baseline_changed' and self.reads==2:value['books'][0]['secret']=1
        if self.mode=='foreign_change' and self.spawns:value['books'][0]['secret']=1
        return value
    def spawn(self,_plan,_credentials):
        self.spawns+=1
        if self.mode=='child_lost':raise TimeoutError()
        target='41' if self.mode=='existing_target' else 'CB_synthetic'
        if target!='41':self.state['books'].append(dict(bookId=target,title='Synthetic',finishReading=0))
        return dict(target=target,counts=dict(shelf=2,credential=1,put=1,notify=1,denied=0))
    def cleanup(self,_credentials,_receipt):
        self.cleanups+=1;self.state['books']=[b for b in self.state['books'] if b['bookId']!='CB_synthetic']
        if self.mode=='cleanup_lost':raise TimeoutError()
        return {'succ':1}


class NativeUploadExecutionTest(unittest.TestCase):
    def test_roundtrip_and_replay_boundary(self):
        journal=Journal(Backend());probe=FakeProbe();grant=credentials()
        result=run(probe,journal,grant,lambda _:True,spawn=probe.spawn,apply=True,sleep=lambda _:None)
        self.assertEqual(result['result'],'NATIVE_SYNTHETIC_ROUNDTRIP_VERIFIED')
        self.assertEqual((probe.spawns,probe.cleanups),(1,1));self.assertEqual(journal.read()[0]['phase'],'restored')
        result=run(probe,journal,grant,lambda _:True,spawn=probe.spawn,apply=True,sleep=lambda _:None)
        self.assertEqual(result['reason'],'native_upload/already_reserved');self.assertEqual((probe.spawns,probe.cleanups),(1,1))
    def test_unknown_results_and_unrelated_change_stop(self):
        for mode,phase,counts in (('baseline_changed',None,(0,0)),('child_lost','launched',(1,0)),
                ('existing_target','launched',(1,0)),('foreign_change','launched',(1,0)),('cleanup_lost','cleanup_pending',(1,1))):
            with self.subTest(mode=mode):
                journal=Journal(Backend());probe=FakeProbe(mode)
                result=run(probe,journal,credentials(),lambda _:True,spawn=probe.spawn,apply=True,sleep=lambda _:None)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual((probe.spawns,probe.cleanups),counts)
                state,_=journal.read();self.assertEqual(state['phase'] if state else None,phase)
    def test_preview_and_default_mode_do_not_dispatch(self):
        journal=Journal(Backend());probe=FakeProbe()
        self.assertEqual(run(probe,journal,credentials(),lambda _:True,spawn=probe.spawn)['result'],'READ_ONLY_PREVIEW')
        self.assertIsNone(journal.read()[0]);self.assertEqual((probe.spawns,probe.cleanups),(0,0))
        with patch('sys.argv',['probe']),patch('verify_native_personal_upload_trial.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main(),0);store.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_transport_only_removes_the_owned_new_target_once(self):
        class Transport:
            def __init__(self):self.calls=[]
            def request(self,stage,url,body=None,credentials=None):
                self.calls.append((stage,url,body));return {'succ':1}
        backend=Backend();journal=Journal(backend);grant=credentials();transport=Transport()
        plan=prepare(grant,source(),'KOReaderSynthetic-0123456789abcdef.txt',b'x');receipt=journal.reserve(plan)
        probe=Probe(journal,lambda _:True,transport)
        with self.assertRaises(ValueError):probe.cleanup(grant,receipt)
        receipt=journal.advance(receipt,'launched');receipt=journal.advance(receipt,'imported',target='CB_synthetic')
        receipt=journal.advance(receipt,'cleanup_pending');self.assertEqual(probe.cleanup(grant,receipt),{'succ':1})
        self.assertEqual(transport.calls[0][2],dict(bookIds=['CB_synthetic'],albumIds=[],archiveIds=[]))
        with self.assertRaises(ValueError):probe.cleanup(grant,receipt)
        self.assertEqual(len(transport.calls),1)
    def test_native_pipe_rejects_ambiguous_or_excess_dispatches(self):
        class Completed:
            returncode=0;stderr=''
            def __init__(self,value):self.stdout='WEREAD_UPLOAD_PROBE='+json.dumps(value)+'\n'
        valid=dict(kind='confirmed',target='CB_synthetic',counts=dict(shelf=2,credential=1,put=1,notify=1,denied=0))
        for mode in ('valid','missing','duplicate','denied'):
            value=deepcopy(valid)
            if mode=='missing':value.pop('target')
            elif mode=='duplicate':value['counts']['notify']=2
            elif mode=='denied':value['counts']['denied']=1
            with self.subTest(mode=mode),patch('verify_native_personal_upload_trial.subprocess.run',return_value=Completed(value)):
                if mode=='valid':self.assertEqual(native_run({'name':'SyntheticUpload.txt'},credentials())['target'],'CB_synthetic')
                else:
                    with self.assertRaises(ValueError):native_run({'name':'SyntheticUpload.txt'},credentials())


if __name__=='__main__':unittest.main()
