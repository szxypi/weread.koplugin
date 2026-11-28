"""Offline tests for the isolated native CB thought coordinator."""
import contextlib
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_highlight_trial import Intent as SeedIntent
from cb_fixture_thought_trial import ThoughtIntent
from test_cb_fixture_highlight_trial import fixture
from test_cb_fixture_thought_trial import Fake
from test_secure_native_session import Backend
from test_verify_cb_fixture_thought_trial import Upload
from verify_cb_fixture_thought_native import main,run


class NativeTrialTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch('verify_cb_fixture_thought_native.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def case(self,fail=None,apply=True):
        sample,baseline,_plan,_body=fixture();sample['baseline']={'chapter':'0','offset':0,'percent':0}
        grant={'vid':'900000','accessToken':'synthetic'};saved={'vid':'900000','cookies':{'wr_vid':'900000'}}
        upload=Upload(sample['book_id'],saved['vid']);seed=SeedIntent(Backend());thought=ThoughtIntent(Backend());natives=[]
        class NativeStore:
            def load(self,_owner):return grant
        class Source:
            def __init__(self):self.samples=[];self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def close(self):pass
            def inspect(self,book):assert book==sample['book_id'];return deepcopy(sample)
        class Native(Fake):
            def __init__(self,book,credentials,authority,_seed,**_kwargs):
                assert book==sample['book_id'] and credentials==grant
                super().__init__(baseline,fail=fail);self.authority=authority;self.posts=0;natives.append(self)
            def version(self,_grant):return 1
            def observe(self,_grant):assert self.authority();return self.read()
            def send(self,phase,body,receipt,_grant):
                assert self.authority();self.posts+=1;return self.seed(phase,body,receipt)
        class Bridge:
            def __init__(self,_command,_owner,_book,_grant,_seed,_thought,authority,_read,**_kwargs):
                self.native=natives[-1];self.authority=authority;self.posts=0;self.dry_verified=False;self.completed=False
            def send(self,phase,body,receipt):
                assert self.authority() and thought.owns(receipt,phase)
                self.dry_verified=True;self.posts+=1;return self.native.thought(phase,body,receipt)
            def finish(self):
                assert self.posts==3 and thought.read()==(None,None);self.completed=True
            def close(self):pass
        def uploader(_probe,_journal,_grant,_check,source,*,apply,cleanup_gate):
            if not apply:return {'result':'READ_ONLY_PREVIEW','phase':'preview'}
            upload.imported=True;assert source(sample['book_id'])
            upload.cleaned=cleanup_gate(upload,upload.receipt,upload.state['plan'],sample['book_id'])
            if upload.cleaned:upload.imported=False
            return {'result':'EPUB_IMPORT_AND_SOURCE_VERIFIED' if upload.cleaned else 'UNVERIFIED',
                    'phase':'restored' if upload.cleaned else 'imported'}
        with patch('verify_cb_fixture_thought_native.save_refreshed_web_session',return_value=False):
            result=run(saved,None,NativeStore(),grant,upload,seed,thought,['synthetic'],apply=apply,uploader=uploader,
                       upload_factory=lambda *_:None,native_factory=Native,source_factory=Source,bridge_factory=Bridge)
        return result,upload,seed,thought,natives

    def test_completed_ui_and_fixture_cleanup(self):
        result,upload,seed,thought,natives=self.case()
        self.assertEqual(result['result'],'CB_NATIVE_THOUGHT_VERIFIED');self.assertTrue(upload.cleaned and not upload.imported)
        self.assertEqual((result['seed_posts'],result['native_thought_steps']),(2,3))
        self.assertTrue(result['dry_run_blocked'] and result['native_ui_completed'])
        self.assertEqual(seed.read(),(None,None));self.assertEqual(thought.read(),(None,None))
        self.assertEqual(natives[0].value,natives[0].original);self.assertNotIn('CB_Synthetic42',json.dumps(result))

    def test_uncertain_write_preserves_fixture_and_journal(self):
        for stage in ('seed_create_pending','thought_create_pending','thought_edit_pending','thought_delete_pending','seed_delete_pending'):
            with self.subTest(stage=stage):
                result,upload,seed,thought,_natives=self.case(fail=stage)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertTrue(upload.imported and not upload.cleaned)
                self.assertTrue(seed.read()[0] or thought.read()[0])

    def test_preview_does_not_create_fixture(self):
        result,upload,seed,thought,natives=self.case(apply=False)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertFalse(upload.imported or natives)
        self.assertEqual(seed.read(),(None,None));self.assertEqual(thought.read(),(None,None))


if __name__=='__main__':unittest.main()
