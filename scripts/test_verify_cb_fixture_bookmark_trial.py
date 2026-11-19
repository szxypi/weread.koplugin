"""Offline owned-fixture and transport checks for CB point bookmarks."""
import contextlib
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_bookmark_trial import Intent,prepare
from test_cb_fixture_bookmark_trial import Fake
from test_cb_fixture_highlight_trial import fixture
from test_secure_native_session import Backend
from test_verify_cb_fixture_highlight_trial import FakeUpload
from verify_cb_fixture_bookmark_trial import main,run
from verify_cb_fixture_highlight_trial import ScopedNative
from verify_eink_login import NativeProbe


class BookmarkCoordinatorTests(unittest.TestCase):
    def test_offline_default(self):
        with patch('verify_cb_fixture_bookmark_trial.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def case(self,failure=None,apply=True,omit_preview=False):
        sample,baseline,_plan,_body=fixture();sample['baseline']={'chapter':'0','offset':0,'percent':0}
        grant={'vid':'900000','accessToken':'synthetic'};saved={'vid':'900000','cookies':{'wr_vid':'900000'}}
        upload=FakeUpload(sample['book_id'],saved['vid'],object());intent=Intent(Backend());natives=[]
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
                super().__init__(baseline,{},fail=failure,omit_preview=omit_preview);self.authority=authority;self.posts=0;natives.append(self)
            def version(self,_grant):return 1
            def observe(self,_grant):assert self.authority();return self.read()
            def send(self,phase,body,receipt,_grant):
                self.posts+=1
                if phase=='create_pending':self.body=deepcopy(body)
                return super().send(phase,body,receipt)
        def uploader(_probe,_journal,_grant,_check,source,*,apply,cleanup_gate):
            if not apply:return {'result':'READ_ONLY_PREVIEW','phase':'preview'}
            upload.imported=True;assert source(sample['book_id'])
            upload.cleaned=cleanup_gate(upload,upload.receipt,upload.state['plan'],sample['book_id'])
            if upload.cleaned:upload.imported=False
            return {'result':'EPUB_IMPORT_AND_SOURCE_VERIFIED' if upload.cleaned else 'UNVERIFIED',
                    'phase':'restored' if upload.cleaned else 'imported'}
        with patch('verify_cb_fixture_highlight_trial.save_refreshed_web_session',return_value=False):
            result=run(saved,None,NativeStore(),grant,upload,intent,apply=apply,uploader=uploader,
                       upload_factory=lambda *_:None,native_factory=Native,source_factory=Source)
        return result,upload,intent,natives

    def test_success_and_preview_presence(self):
        for omitted in (False,True):
            result,upload,intent,natives=self.case(omit_preview=omitted)
            self.assertEqual(result['result'],'CB_FIXTURE_BOOKMARK_VERIFIED');self.assertTrue(upload.cleaned and not upload.imported)
            self.assertEqual(result['annotation_posts'],2);self.assertEqual(result['server_preview_returned'],not omitted)
            self.assertEqual(intent.read(),(None,None));self.assertEqual(natives[0].value,natives[0].original)
            self.assertNotIn('CB_Synthetic42',json.dumps(result))

    def test_uncertain_write_preserves_fixture(self):
        for phase in ('create_pending','delete_pending'):
            result,upload,intent,_natives=self.case(failure=phase)
            self.assertEqual(result['result'],'UNVERIFIED');self.assertTrue(upload.imported and not upload.cleaned)
            self.assertEqual(intent.read()[0]['phase'],phase)

    def test_preview_no_write(self):
        result,upload,intent,natives=self.case(apply=False)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertFalse(upload.imported or natives)
        self.assertEqual(intent.read(),(None,None))

    def test_transport_refuses_unclaimed_foreign_and_repeated_write(self):
        sample,baseline,_plan,_body=fixture();plan,body=prepare('900000','CB_Synthetic42','a'*32,sample,1,baseline)
        grant={'vid':'900000','accessToken':'synthetic'};intent=Intent(Backend())
        native=ScopedNative(sample['book_id'],grant,lambda:True,intent);native.body=body
        with patch.object(NativeProbe,'request',return_value={'succ':1}) as request:
            receipt=intent.reserve(plan)
            with self.assertRaises(ValueError):native.send('create_pending',dict(body,bookId='CB_Other'),receipt,grant)
            native.send('create_pending',body,receipt,grant)
            with self.assertRaises(ValueError):native.send('create_pending',body,receipt,grant)
            with self.assertRaises(ValueError):native.send('delete_pending',{'bookmarkIds':['original']},receipt,grant)
            self.assertEqual(request.call_count,1)


if __name__=='__main__':unittest.main()
