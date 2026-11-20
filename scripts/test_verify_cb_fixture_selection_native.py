"""Offline orchestration checks for the native CB selection trial."""
import contextlib
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_selection_trial import Intent
from test_cb_fixture_highlight_trial import fixture
from test_cb_fixture_selection_trial import Fake
from test_secure_native_session import Backend
from test_verify_cb_fixture_thought_trial import Upload
from verify_cb_fixture_selection_native import main,run


class NativeSelectionTests(unittest.TestCase):
    def test_offline_default(self):
        with patch('verify_cb_fixture_selection_native.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def case(self,fail=None,apply=True,associated=False):
        sample,baseline,_plan,_body=fixture();sample['chapters'][0].update(chapterIdx=2,wordCount=100)
        sample['baseline']={'chapter':'0','offset':0,'percent':0}
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
                super().__init__(baseline,fail=fail,associated=associated);self.authority=authority;self.cleanup_posts=0;natives.append(self)
            def version(self,_grant):return 1
            def observe(self,_grant):assert self.authority();return self.read()
            def send_cleanup(self,body,receipt,_grant):
                self.cleanup_posts+=1;return self.cleanup(body,receipt)
        class Bridge:
            def __init__(self,_command,payload,_plan,_baseline,_intent,authority,_read):
                assert payload['book']==sample['book_id'] and payload['body']['isPrivate']==1
                self.native=natives[-1];self.authority=authority;self.steps=0;self.dry_verified=False;self.completed=False
            def send(self,step,body,receipt):
                assert self.authority() and intent.read()[1]==receipt
                self.dry_verified=True;self.steps+=1;return self.native.thought(step,body,receipt)
            def finish(self):
                assert self.steps==3 and intent.read()[0]['cleanup_verified'];self.completed=True
                if fail=='finish':raise RuntimeError('synthetic runner failure')
            def close(self):pass
        def uploader(_probe,_journal,_grant,_check,source,*,apply,cleanup_gate):
            if not apply:return {'result':'READ_ONLY_PREVIEW','phase':'preview'}
            upload.imported=True;assert source(sample['book_id'])
            upload.cleaned=cleanup_gate(upload,upload.receipt,upload.state['plan'],sample['book_id'])
            if upload.cleaned:upload.imported=False
            return {'result':'EPUB_IMPORT_AND_SOURCE_VERIFIED' if upload.cleaned else 'UNVERIFIED',
                    'phase':'restored' if upload.cleaned else 'imported'}
        with patch('verify_cb_fixture_selection_native.save_refreshed_web_session',return_value=False):
            result=run(saved,None,NativeStore(),grant,upload,intent,['synthetic'],apply=apply,uploader=uploader,
                       upload_factory=lambda *_:None,native_factory=Native,source_factory=Source,bridge_factory=Bridge)
        return result,upload,intent,natives

    def test_success_with_or_without_associated_mark(self):
        for associated in (False,True):
            result,upload,intent,natives=self.case(associated=associated)
            self.assertEqual(result['result'],'CB_NATIVE_SELECTION_VERIFIED');self.assertTrue(upload.cleaned and not upload.imported)
            self.assertEqual((result['native_thought_steps'],result['cleanup_posts']),(3,int(associated)))
            self.assertTrue(result['dry_run_blocked'] and result['native_ui_completed'] and result['fresh_offline'])
            self.assertEqual(intent.read(),(None,None));self.assertEqual(natives[0].value,natives[0].original)
            self.assertNotIn('CB_Synthetic42',json.dumps(result))

    def test_uncertain_write_or_runner_failure_keeps_fixture(self):
        for phase in ('thought1','thought2','thought3','cleanup','finish'):
            with self.subTest(phase=phase):
                result,upload,intent,_natives=self.case(fail=phase,associated=True)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertTrue(upload.imported and not upload.cleaned)
                self.assertEqual(intent.read()[0]['phase'],'pending')

    def test_preview_no_write(self):
        result,upload,intent,natives=self.case(apply=False)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertFalse(upload.imported or natives)
        self.assertEqual(intent.read(),(None,None))


if __name__=='__main__':unittest.main()
