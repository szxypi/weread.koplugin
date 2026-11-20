"""Synthetic EPUB import must remain one-shot and clean only proven targets."""
import contextlib,io,json,unittest
from copy import deepcopy
from urllib.parse import parse_qs,urlsplit
from unittest.mock import patch
from synthetic_epub_trial import Journal
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend,credentials
from verify_synthetic_epub_upload import main,read_source,run
from synthetic_upload_epub import TEXT
from synthetic_upload_epub import build
from test_native_shelf_trial import source
from verify_personal_upload_trial import Probe


class EpubUploadExecutionTest(unittest.TestCase):
    def test_success_cleans_once_and_cannot_replay(self):
        probe=FakeProbe();journal=Journal(Backend());calls=[]
        def read(identity):calls.append(identity);return True
        result=run(probe,journal,credentials(),lambda _:True,read,apply=True,sleep=lambda _:None,now=lambda:1000)
        self.assertEqual(result['result'],'EPUB_IMPORT_AND_SOURCE_VERIFIED');self.assertTrue(result['source_verified'])
        self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1));self.assertEqual(len(calls),1);self.assertEqual(journal.read()[0]['phase'],'restored')
        again=run(probe,journal,credentials(),lambda _:True,read,apply=True,sleep=lambda _:None,now=lambda:1000)
        self.assertEqual(again['reason'],'synthetic_epub/already_reserved');self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
    def test_failed_read_still_cleans_exact_observed_item_but_never_claims_source_verified(self):
        for read in (lambda _identity:False,lambda _identity:(_ for _ in ()).throw(TimeoutError())):
            probe=FakeProbe();journal=Journal(Backend())
            result=run(probe,journal,credentials(),lambda _:True,read,apply=True,sleep=lambda _:None,now=lambda:1000)
            self.assertEqual(result['result'],'EPUB_IMPORTED_SOURCE_UNVERIFIED');self.assertFalse(result['source_verified'])
            self.assertEqual(probe.attempts['cleanup'],1);self.assertEqual(journal.read()[0]['phase'],'restored')
    def test_dependent_cleanup_requires_explicit_success_and_never_replays(self):
        for gate in (lambda *_:False, lambda *_:None, lambda *_:1,
                     lambda *_:(_ for _ in ()).throw(TimeoutError())):
            with self.subTest(gate=gate):
                probe=FakeProbe();journal=Journal(Backend())
                result=run(probe,journal,credentials(),lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000,cleanup_gate=gate)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(probe.attempts['cleanup'],0)
                self.assertEqual(journal.read()[0]['phase'],'imported')
                again=run(probe,journal,credentials(),lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000,cleanup_gate=gate)
                self.assertEqual(again['reason'],'synthetic_epub/already_reserved');self.assertEqual(probe.attempts['cleanup'],0)
        probe=FakeProbe();journal=Journal(Backend());observed=[]
        def allow(store,receipt,plan,target):
            state,current=store.read();observed.append((state['phase'],current==receipt,state['plan']==plan,state['target']==target))
            return True
        result=run(probe,journal,credentials(),lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000,cleanup_gate=allow)
        self.assertEqual(observed,[('imported',True,True,True)]);self.assertEqual(probe.attempts['cleanup'],1)
        self.assertEqual(result['result'],'EPUB_IMPORT_AND_SOURCE_VERIFIED')
    def test_unknown_write_or_foreign_change_never_continues(self):
        for mode,phase,counts in (('baseline_changed',None,(0,0,0,0)),('credential_lost','credential_pending',(1,0,0,0)),
                ('put_lost','upload_pending',(1,1,0,0)),('notify_lost','notify_pending',(1,1,1,0)),
                ('notify_invalid','notify_pending',(1,1,1,0)),('existing_target','notify_pending',(1,1,1,0)),
                ('foreign_change','notify_pending',(1,1,1,0)),('cleanup_lost','cleanup_pending',(1,1,1,1))):
            with self.subTest(mode=mode):
                probe=FakeProbe(mode);journal=Journal(Backend())
                result=run(probe,journal,credentials(),lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(tuple(probe.attempts.values()),counts)
                state,_=journal.read();self.assertEqual(state['phase'] if state else None,phase)
    def test_preview_and_default_never_access_upload(self):
        probe=FakeProbe();journal=Journal(Backend())
        self.assertEqual(run(probe,journal,credentials(),lambda _:True,lambda _:True)['result'],'READ_ONLY_PREVIEW')
        self.assertFalse(any(probe.attempts.values()));self.assertIsNone(journal.read()[0])
        with patch('verify_synthetic_epub_upload.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0);store.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_source_check_is_bound_to_target_and_stable_catalog_and_position(self):
        class Web:
            def __init__(self):self.samples=[];self.allowed=set();self.accounts=0;self.closed=False
            def set_cookie(self,_name,_value):pass
            def verify_account(self):self.accounts+=1
            def inspect(self,target):
                self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
                self.asserted=target in self.allowed
                return dict(book_id=target,source_format='web_xhtml',source=TEXT)
            def close(self):self.closed=True
        web=Web();saved=dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='synthetic-private-cookie'))
        with patch('verify_synthetic_epub_upload.CbReadingProbe',return_value=web):
            self.assertTrue(read_source(saved,'CB_SyntheticOnly',sleep=lambda _:None))
        self.assertTrue(web.asserted and web.closed);self.assertEqual(web.accounts,2)
        with self.assertRaises(ValueError):read_source(saved,'41')
    def test_complete_transport_preserves_epub_name_bytes_and_single_cleanup(self):
        class Response:
            status=200
            def __init__(self,body):self.body=body
            def __enter__(self):return self
            def __exit__(self,*_args):return False
            def read(self,_limit):return self.body
        class Service:
            def __init__(self):self.shelf=source();self.calls=[]
            def open(self,request,timeout):
                self.calls.append(request);parsed=urlsplit(request.full_url);query=parse_qs(parsed.query,keep_blank_values=True)
                if parsed.path=='/shelf/sync':value=self.shelf
                elif parsed.path=='/cos/getcredential':
                    self_test.assertTrue(query['name'][0].startswith('KOReaderSynthetic-'));self_test.assertFalse(query['name'][0].endswith('.epub'))
                    value=dict(bucket='synthetic-12345',ObjectName='/prefix/synthetic-book',Response=dict(ExpiredTime=1300,
                        Credentials=dict(TmpSecretId='synthetic-id',TmpSecretKey='synthetic-key',Token='synthetic-token')))
                elif parsed.path=='/prefix/synthetic-book':
                    self_test.assertEqual(request.data,build());return Response(b'')
                elif parsed.path=='/cos/notify':
                    self_test.assertTrue(query['name'][0].endswith('.epub'));self_test.assertEqual(json.loads(request.data),{})
                    self.shelf['books'].append(dict(bookId='CB_synthetic123',title='Synthetic',finishReading=0))
                    value={'status':1,'bookId':'CB_synthetic123'}
                elif parsed.path=='/shelf/delete':
                    self_test.assertEqual(json.loads(request.data),dict(bookIds=['CB_synthetic123'],albumIds=[],archiveIds=[]))
                    self.shelf['books']=[b for b in self.shelf['books'] if b['bookId']!='CB_synthetic123'];value={'succ':1}
                else:raise AssertionError('unexpected route')
                return Response(json.dumps(deepcopy(value)).encode())
        self_test=self;service=Service();journal=Journal(Backend());grant=credentials()
        probe=Probe(journal,lambda _:True,opener=service,cos_opener=service)
        result=run(probe,journal,grant,lambda _:True,lambda target:target=='CB_synthetic123',apply=True,sleep=lambda _:None,now=lambda:1000)
        self.assertEqual(result['result'],'EPUB_IMPORT_AND_SOURCE_VERIFIED');self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
        self.assertEqual(journal.read()[0]['phase'],'restored')


if __name__=='__main__':unittest.main()
