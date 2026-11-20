"""Fixture-only thought workflow and transport guards, with no real account."""
import contextlib
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from annotation_experiment_model import digest,note_text
from cb_fixture_highlight_trial import Intent as SeedIntent
from cb_fixture_thought_trial import PROTOCOL,ThoughtIntent
from test_cb_fixture_highlight_trial import fixture
from test_cb_fixture_thought_trial import Fake
from test_secure_native_session import Backend
from verify_cb_fixture_thought_trial import ScopedThoughtNative,main,run
from verify_eink_login import BASE,NativeProbe


class Upload:
    def __init__(self,book,owner):
        self.state=dict(phase='imported',target=book,attempt='a'*32,plan={'owner':owner})
        self.receipt=object();self.imported=False;self.cleaned=False
    def read(self):return (self.state,self.receipt) if self.imported else (None,None)


class TrialTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch('verify_cb_fixture_thought_trial.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

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
            def __init__(self,book,credentials,authority,_seed,_thought):
                assert book==sample['book_id'] and credentials==grant
                super().__init__(baseline,fail=fail);self.authority=authority;self.posts=0;self.thought_posts=0;natives.append(self)
            def version(self,_grant):return 1
            def observe(self,_grant):assert self.authority();return self.read()
            def send(self,phase,body,receipt,_grant):
                assert self.authority();self.posts+=1;return self.seed(phase,body,receipt)
            def send_thought(self,phase,body,receipt,_grant):
                assert self.authority();self.thought_posts+=1;return self.thought(phase,body,receipt)
        def uploader(_probe,_journal,_grant,_check,source,*,apply,cleanup_gate):
            if not apply:return {'result':'READ_ONLY_PREVIEW','phase':'preview'}
            upload.imported=True;assert source(sample['book_id'])
            upload.cleaned=cleanup_gate(upload,upload.receipt,upload.state['plan'],sample['book_id'])
            if upload.cleaned:upload.imported=False
            return {'result':'EPUB_IMPORT_AND_SOURCE_VERIFIED' if upload.cleaned else 'UNVERIFIED',
                    'phase':'restored' if upload.cleaned else 'imported'}
        with patch('verify_cb_fixture_thought_trial.save_refreshed_web_session',return_value=False):
            result=run(saved,None,NativeStore(),grant,upload,seed,thought,apply=apply,uploader=uploader,
                       upload_factory=lambda *_:None,native_factory=Native,source_factory=Source)
        return result,upload,seed,thought,natives

    def test_isolated_success_and_original_restore(self):
        result,upload,seed,thought,natives=self.case()
        self.assertEqual(result['result'],'CB_FIXTURE_THOUGHT_VERIFIED');self.assertTrue(upload.cleaned and not upload.imported)
        self.assertEqual((result['seed_posts'],result['thought_posts']),(2,3));self.assertEqual(seed.read(),(None,None))
        self.assertEqual(thought.read(),(None,None));self.assertEqual(natives[0].value,natives[0].original)
        self.assertNotIn('CB_Synthetic42',json.dumps(result))

    def test_uncertain_write_preserves_fixture(self):
        for stage in ('seed_create_pending','thought_create_pending','thought_edit_pending','thought_delete_pending','seed_delete_pending'):
            result,upload,seed,thought,_natives=self.case(fail=stage)
            self.assertEqual(result['result'],'UNVERIFIED');self.assertTrue(upload.imported and not upload.cleaned)
            self.assertTrue(seed.read()[0] or thought.read()[0])

    def test_preview_does_not_create_fixture(self):
        result,upload,seed,thought,natives=self.case(apply=False)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertFalse(upload.imported or natives)
        self.assertEqual(seed.read(),(None,None));self.assertEqual(thought.read(),(None,None))

    def test_transport_requires_matching_private_body_and_one_shot_phase(self):
        nonce='b'*32;book='CB_Synthetic42';grant={'vid':'900000','accessToken':'synthetic'}
        create=dict(bookId=book,chapterUid='2',bookVersion=1,type=1,range='9-30',abstract='Synthetic quote',
                    isPrivate=1,content=note_text(nonce))
        plan=dict(protocol=PROTOCOL,owner_sha256=digest('900000'),book_sha256=digest(book),attempt='a'*32,nonce=nonce,
                  context_sha256='0'*64,baseline_sha256='1'*64,seed_sha256='2'*64,request_sha256=digest(create))
        seed=SeedIntent(Backend());thought=ThoughtIntent(Backend());native=ScopedThoughtNative(book,grant,lambda:True,seed,thought)
        receipt=thought.prepare(plan);receipt=thought.advance(receipt,'prepared','create_pending')
        with patch.object(NativeProbe,'request',return_value={'succ':1}) as request:
            with self.assertRaises(ValueError):native.send_thought('create_pending',dict(create,isPrivate=0),receipt,grant)
            with self.assertRaises(ValueError):native.send_thought('create_pending',dict(create,bookId='CB_Other'),receipt,grant)
            native.send_thought('create_pending',create,receipt,grant)
            self.assertEqual(request.call_count,1)
            with self.assertRaises(ValueError):native.send_thought('create_pending',create,receipt,grant)
            with self.assertRaises(ValueError):native.request('thought_edit_pending',BASE+'/review/useredit',{},grant)
            self.assertEqual(request.call_count,1)


if __name__=='__main__':unittest.main()
