"""An interrupted fixture can continue only before any UI write claim."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from cb_existing_position_intent import Intent
from test_cb_fixture_position_transport import MemoryBackend
import resume_cb_fixture_reconnect_trial as task
import inspect_cb_fixture_reconnect_trial as inspection
import cleanup_cb_fixture_reconnect_completed as cleanup
import inspect_cb_fixture_reconnect_restored as restored
from copy import deepcopy
from reading_epub_trial import prepare as reading_prepare
from test_native_shelf_trial import source
from test_secure_native_session import credentials


class ResumeTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as output:self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
    def test_inspection_default_is_offline(self):
        with patch.object(inspection,'SessionStore') as store,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(inspection.inspect([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_cleanup_offline_default_does_not_load_sessions(self):
        with patch.object(cleanup,'SessionStore') as store,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(cleanup.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
    def test_cleanup_rejects_grouped_or_marked_fixture(self):
        source={'books':[{'bookId':'CB_Test','secret':1,'finishReading':0}],'archive':[]}
        self.assertTrue(cleanup.validate_fixture_shelf(source,'CB_Test'))
        for changed in ({'books':[{'bookId':'CB_Test','secret':0,'finishReading':0}],'archive':[]},
                        {'books':[{'bookId':'CB_Test','secret':1,'finishReading':1}],'archive':[]},
                        {'books':[{'bookId':'CB_Test','isTop':1,'secret':1,'finishReading':0}],'archive':[]},
                        {'books':[{'bookId':'CB_Test','secret':1,'finishReading':0}],'archive':[{'bookIds':['CB_Test']}]} ,
                        {'books':[],'archive':[]}):
            with self.subTest(changed=changed),self.assertRaises(ValueError):cleanup.validate_fixture_shelf(changed,'CB_Test')

    def test_restored_independent_check_requires_both_channels(self):
        grant=credentials();baseline=source();plan=reading_prepare(grant,baseline,'KOReaderSynthetic-0123456789abcdef.epub')
        self.assertTrue(restored.assess(plan,'CB_Test',grant,lambda:(deepcopy(baseline),deepcopy(baseline)))['native_original_shelf_verified'])
        for channel in ('native','web'):
            def changed():
                n,w=deepcopy(baseline),deepcopy(baseline)
                (n if channel=='native' else w)['books'].append({'bookId':'CB_Test','title':'Synthetic'})
                return n,w
            with self.subTest(channel=channel),self.assertRaises(ValueError):restored.assess(plan,'CB_Test',grant,changed)

    def test_source_rechecks_use_fresh_single_use_readers(self):
        instances=[]
        class SingleUse:
            def __init__(self):
                self.reads=0;self.samples=[];self.catalog_versions={'version':1}
                self.last_checks={'catalog_unchanged':True,'versions_unchanged':True,'position_unchanged':True}
                self.closed=False;instances.append(self)
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def inspect(self,book):
                self.reads+=1
                if self.reads!=1:raise ValueError('reader reused')
                return {'book_id':book,'source_format':'web_xhtml','source':task.TEXT}
            def close(self):self.closed=True
        for _ in range(2):
            value,versions=task.read_source('900000','CB_Test',{},factory=SingleUse)
            self.assertEqual(value['book_id'],'CB_Test');self.assertEqual(versions,{'version':1})
        self.assertEqual(len(instances),2);self.assertTrue(all(item.closed and item.reads==1 for item in instances))

    def test_only_exact_zero_claim_is_eligible(self):
        store=Intent(backend=MemoryBackend());value=store.reserve('900000','CB_Test','a'*32,'b'*64);raw=store.backend.load()
        self.assertEqual(task.verify_intent(store,raw,'900000','CB_Test','a'*32,'b'*64,0),value)
        for owner,target,attempt,baseline,claimed in (('900001','CB_Test','a'*32,'b'*64,0),('900000','CB_Other','a'*32,'b'*64,0),
            ('900000','CB_Test','c'*32,'b'*64,0),('900000','CB_Test','a'*32,'c'*64,0),('900000','CB_Test','a'*32,'b'*64,1)):
            with self.subTest(owner=owner,target=target,claimed=claimed),self.assertRaises(ValueError):
                task.verify_intent(store,raw,owner,target,attempt,baseline,claimed)
        store.claim(value,'write_enter')
        with self.assertRaises(ValueError):task.verify_intent(store,store.backend.load(),'900000','CB_Test','a'*32,'b'*64,0)
    def test_cleanup_claims_before_one_write_and_never_replays_unknown(self):
        class Journal:
            def __init__(self):self.phase='imported'
            def advance(self,receipt,phase):
                if receipt!=self.phase or (self.phase,phase) not in (('imported','cleanup_pending'),('cleanup_pending','restored')):
                    raise ValueError('sequence')
                self.phase=phase;return phase
        class Probe:
            def __init__(self,journal,ack):self.journal=journal;self.ack=ack;self.posts=0
            def shelf(self,_grant):return {}
            def cleanup(self,_grant,receipt):
                assert receipt==self.journal.phase=='cleanup_pending';self.posts+=1;return self.ack
        for ack,readback,success in (({'succ':1},True,True),({},True,False),({'succ':1},False,False)):
            journal=Journal();probe=Probe(journal,ack)
            kwargs=dict(check=lambda *_args:True,observe=lambda *_args:readback)
            if success:
                self.assertTrue(task.cleanup_once(journal,'imported',{},'CB_Test',{},probe,lambda:True,**kwargs))
                self.assertEqual(journal.phase,'restored')
            else:
                with self.assertRaises(ValueError):task.cleanup_once(journal,'imported',{},'CB_Test',{},probe,lambda:True,**kwargs)
                self.assertEqual(journal.phase,'cleanup_pending')
                with self.assertRaises(ValueError):task.cleanup_once(journal,'imported',{},'CB_Test',{},probe,lambda:True,**kwargs)
            self.assertEqual(probe.posts,1)
    def test_changed_session_stops_before_claim(self):
        journal=type('Journal',(),{'advance':lambda *_args:(_ for _ in ()).throw(AssertionError('claimed'))})()
        with self.assertRaises(ValueError):task.cleanup_once(journal,b'old',{},'CB_Test',{},None,lambda:False)

if __name__=='__main__':unittest.main()
