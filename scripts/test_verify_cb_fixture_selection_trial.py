"""Offline workflow and transport tests for a fresh CB selection."""
import contextlib
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from annotation_experiment_model import digest,note_text
from cb_fixture_selection_trial import Intent,PROTOCOL
from test_cb_fixture_highlight_trial import fixture
from test_cb_fixture_selection_trial import Fake
from test_secure_native_session import Backend
from test_verify_cb_fixture_thought_trial import Upload
from verify_cb_fixture_selection_trial import ScopedSelectionNative,main,run
from verify_eink_login import BASE,NativeProbe


class SelectionCoordinatorTests(unittest.TestCase):
    def test_offline_default(self):
        with patch('verify_cb_fixture_selection_trial.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def case(self,fail=None,apply=True,associated=False):
        sample,baseline,_plan,_body=fixture();sample['baseline']={'chapter':'0','offset':0,'percent':0}
        grant={'vid':'900000','accessToken':'synthetic'};saved={'vid':'900000','cookies':{'wr_vid':'900000'}}
        upload=Upload(sample['book_id'],saved['vid']);intent=Intent(Backend());natives=[]
        class NativeStore:
            def load(self,_owner):return grant
        class Source:
            def __init__(self):self.samples=[];self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def close(self):pass
            def inspect(self,book):assert book==sample['book_id'];return deepcopy(sample)
        class Native(Fake):
            def __init__(self,book,credentials,authority,_intent):
                assert book==sample['book_id'] and credentials==grant
                super().__init__(baseline,fail=fail,associated=associated);self.authority=authority
                self.thought_posts=0;self.cleanup_posts=0;natives.append(self)
            def version(self,_grant):return 1
            def observe(self,_grant):assert self.authority();return self.read()
            def send_thought(self,step,body,receipt,_grant):
                self.thought_posts+=1;return self.thought(step,body,receipt)
            def send_cleanup(self,body,receipt,_grant):
                self.cleanup_posts+=1;return self.cleanup(body,receipt)
        def uploader(_probe,_journal,_grant,_check,source,*,apply,cleanup_gate):
            if not apply:return {'result':'READ_ONLY_PREVIEW','phase':'preview'}
            upload.imported=True;assert source(sample['book_id'])
            upload.cleaned=cleanup_gate(upload,upload.receipt,upload.state['plan'],sample['book_id'])
            if upload.cleaned:upload.imported=False
            return {'result':'EPUB_IMPORT_AND_SOURCE_VERIFIED' if upload.cleaned else 'UNVERIFIED',
                    'phase':'restored' if upload.cleaned else 'imported'}
        with patch('verify_cb_fixture_selection_trial.save_refreshed_web_session',return_value=False):
            result=run(saved,None,NativeStore(),grant,upload,intent,apply=apply,uploader=uploader,
                       upload_factory=lambda *_:None,native_factory=Native,source_factory=Source)
        return result,upload,intent,natives

    def test_success_with_or_without_associated_mark(self):
        for associated in (False,True):
            result,upload,intent,natives=self.case(associated=associated)
            self.assertEqual(result['result'],'CB_FIXTURE_SELECTION_VERIFIED');self.assertTrue(upload.cleaned and not upload.imported)
            self.assertEqual((result['thought_posts'],result['cleanup_posts']),(3,int(associated)))
            self.assertEqual(result['associated_highlight_observed'],associated);self.assertEqual(intent.read(),(None,None))
            self.assertEqual(natives[0].value,natives[0].original);self.assertNotIn('CB_Synthetic42',json.dumps(result))

    def test_uncertain_write_preserves_fixture(self):
        for phase in ('thought1','thought2','thought3','cleanup'):
            with self.subTest(phase=phase):
                result,upload,intent,_natives=self.case(fail=phase,associated=True)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertTrue(upload.imported and not upload.cleaned)
                self.assertEqual(intent.read()[0]['phase'],'pending')

    def test_preview_no_write(self):
        result,upload,intent,natives=self.case(apply=False)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertFalse(upload.imported or natives)
        self.assertEqual(intent.read(),(None,None))

    def test_transport_refuses_foreign_payload_and_replay(self):
        nonce='b'*32;book='CB_Synthetic42';grant={'vid':'900000','accessToken':'synthetic'}
        create=dict(bookId=book,chapterUid='2',bookVersion=1,type=1,range='9-30',abstract='Synthetic quote',
                    isPrivate=1,content=note_text(nonce))
        plan=dict(protocol=PROTOCOL,owner_sha256=digest('900000'),book_sha256=digest(book),attempt='a'*32,nonce=nonce,
                  source_sha256='0'*64,context_sha256='1'*64,baseline_sha256='2'*64,request_sha256=digest(create))
        intent=Intent(Backend());native=ScopedSelectionNative(book,grant,lambda:True,intent)
        receipt=intent.prepare(plan);receipt=intent.claim(receipt)
        with patch.object(NativeProbe,'request',return_value={'succ':1}) as request:
            with self.assertRaises(ValueError):native.send_thought(1,dict(create,isPrivate=0),receipt,grant)
            with self.assertRaises(ValueError):native.send_thought(1,dict(create,bookId='CB_Other'),receipt,grant)
            native.send_thought(1,create,receipt,grant);self.assertEqual(request.call_count,1)
            with self.assertRaises(ValueError):native.send_thought(1,create,receipt,grant)
            with self.assertRaises(ValueError):native.request('selection_cleanup',BASE+'/book/removeBookmark',{},grant)
            self.assertEqual(request.call_count,1)


if __name__=='__main__':unittest.main()
