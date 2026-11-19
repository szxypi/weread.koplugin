"""Offline source, one-shot and isolated fixture checks for TXT highlights."""
from copy import deepcopy
import contextlib
import hashlib
import io
import json
import unittest
from unittest.mock import patch

import cb_txt_highlight_trial as trial
import verify_cb_txt_highlight_trial as verify
from personal_upload_trial import Journal
from test_cb_fixture_highlight_trial import Fake
from test_native_shelf_trial import source
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend,credentials
from verify_cb_fixture_highlight_trial import run as run_highlight
from verify_cb_txt_fixture import Receipt
from verify_synthetic_epub_upload import run as upload_run


def sample():
    book='CB_Synthetic42';raw=trial.BODY.decode()
    value=dict(book_id=book,chapter_uid='2',chapters=[{'chapterUid':2}],source_format='web_txt',
               source=raw,source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
    baseline=dict(shelf={'fixture':True},position={'chapter':'0'},thoughts={},marks=dict(updated={},chapters={}))
    plan,body=trial.prepare('900000',book,'a'*32,value,1,baseline)
    return value,baseline,plan,body


class TxtHighlightTests(unittest.TestCase):
    def test_offline_default_never_reads_credentials(self):
        with patch.object(verify,'SessionStore',side_effect=AssertionError('credential access')):
            with contextlib.redirect_stdout(io.StringIO()) as output:self.assertEqual(verify.main([]),0)
        self.assertEqual(json.loads(output.getvalue()),dict(result='OFFLINE_ONLY',annotation_posts=0))

    def test_plain_rune_range_is_distinct_from_utf16_and_bound_to_source(self):
        value,baseline,plan,body=sample();raw=value['source'];start,end=map(int,body['range'].split('-'))
        self.assertEqual(raw[start:end],trial.TEXT)
        self.assertEqual(len(raw[:start].encode('utf-16-le'))//2,start+1)
        self.assertNotIn(trial.TEXT,str(plan));self.assertNotIn(value['book_id'],str(plan))
        for modified in (dict(value,book_id='CB_Other'),dict(value,source_format='web_xhtml'),
                         dict(value,source=raw+trial.TEXT),dict(value,source=raw.replace('😀','x')),
                         dict(value,source_raw_sha256='0'*64),dict(value,chapters=[{'chapterUid':2},{'chapterUid':'2'}])):
            with self.subTest(modified=modified),self.assertRaises(ValueError):
                trial.prepare('900000',value['book_id'],'a'*32,modified,1,baseline)
        occupied=deepcopy(baseline);occupied['marks']['updated']['existing']={}
        with self.assertRaises(ValueError):trial.prepare('900000',value['book_id'],'a'*32,value,1,occupied)

    def test_two_step_receipt_and_unconfirmed_outcome_never_replay(self):
        _,baseline,plan,body=sample()
        for fail in (None,'create_pending','delete_pending'):
            fake=Fake(baseline,body,fail);intent=trial.Intent(Backend())
            if fail:
                with self.assertRaises(RuntimeError):trial.execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send)
                previous=list(fake.sent)
                with self.assertRaises(Exception):trial.execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send)
                self.assertEqual(fake.sent,previous);self.assertIsNotNone(intent.read()[0])
            else:
                result=trial.execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send)
                self.assertEqual(result['writes'],2);self.assertEqual(fake.current,baseline);self.assertEqual(intent.read(),(None,None))

    def test_uploaded_identity_requires_both_matching_receipts(self):
        grant=credentials();journal=Journal(Backend(),validator=verify.validate_plan);receipt=Receipt(Backend())
        plan=verify.prepare_plan(grant,source(),'KOReaderSynthetic-0123456789abcdef.txt')
        claim=journal.reserve(plan);claim=journal.advance(claim,'credential_pending')
        claim=journal.advance(claim,'credential_ready',object_sha256='a'*64)
        for phase in ('upload_pending','uploaded','notify_pending'):claim=journal.advance(claim,phase)
        target='CB_synthetic123';receipt.record(journal,claim,plan,target)
        claim=journal.advance(claim,'imported',target=target)
        same=lambda value:value==grant
        self.assertTrue(verify.fixture_authorized(journal,claim,target,grant['vid'],grant,same,receipt))
        self.assertFalse(verify.fixture_authorized(journal,claim,'CB_other',grant['vid'],grant,same,receipt))
        self.assertFalse(verify.fixture_authorized(journal,claim,target,grant['vid'],grant,lambda _:False,receipt))
        receipt.backend.save(b'wrong')
        self.assertFalse(verify.fixture_authorized(journal,claim,target,grant['vid'],grant,same,receipt))

    def test_full_synthetic_import_and_two_writes_are_isolated_and_cleaned(self):
        grant=credentials();saved=dict(vid=grant['vid'],cookies={});probe=FakeProbe()
        journal=Journal(Backend(),validator=verify.validate_plan);receipt=Receipt(Backend());intent=trial.Intent(Backend())
        baseline=dict(shelf={'fixture':True},position={'chapter':'0'},thoughts={},marks=dict(updated={},chapters={}))
        class NativeStore:
            def load(self,_owner):return grant
        class Web:
            def __init__(self):self.samples=[];self.last_checks={}
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def close(self):pass
            def inspect(self,target):
                raw=trial.BODY.decode();self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
                return dict(book_id=target,chapter_uid='2',chapters=[{'chapterUid':2}],source_format='web_txt',
                            source=raw,source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),baseline={'chapter':'0'})
        class Native:
            def __init__(self,book,_grant,authority,_intent):
                self.book=book;self.authority=authority;self.posts=0;self.body=None;self.current=deepcopy(baseline)
            def observe(self,_grant):return deepcopy(self.current)
            def version(self,_grant):return 1
            def send(self,phase,body,_receipt,_grant):
                assert self.authority();self.posts+=1
                if phase=='create_pending':
                    assert body==self.body
                    self.current['marks']['updated']['synthetic-mark']=dict(body,bookmarkId='synthetic-mark')
                else:
                    assert body=={'bookmarkIds':['synthetic-mark']};self.current['marks']['updated'].clear()
        def runner(*args,**kwargs):
            return run_highlight(*args,**kwargs,upload_factory=lambda *_:probe,native_factory=Native,
                                 source_factory=Web,source_sleep=lambda _:None)
        def uploader(*args,**kwargs):return upload_run(*args,**kwargs,sleep=lambda _:None,now=lambda:1000)
        with patch('verify_cb_fixture_highlight_trial.save_refreshed_web_session',return_value=False):
            result=verify.run(saved,None,NativeStore(),grant,journal,receipt,intent,apply=True,runner=runner,uploader=uploader)
        self.assertEqual(result['result'],'CB_TXT_HIGHLIGHT_VERIFIED')
        self.assertEqual(result['annotation_posts'],2);self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
        self.assertEqual(journal.read()[0]['phase'],'restored');self.assertEqual(intent.read(),(None,None))
        self.assertNotIn(trial.TEXT,json.dumps(result));self.assertNotIn('CB_synthetic123',json.dumps(result))

    def test_unconfirmed_dependent_step_retains_fixture_and_blocks_replay(self):
        grant=credentials();saved=dict(vid=grant['vid'],cookies={});probe=FakeProbe()
        journal=Journal(Backend(),validator=verify.validate_plan);receipt=Receipt(Backend());intent=trial.Intent(Backend())
        def runner(_saved,_session,_native,_grant,journal_arg,_intent,**options):
            return options['uploader'](probe,journal_arg,grant,lambda value:value==grant,lambda _:True,
                                       apply=True,cleanup_gate=lambda *_:False)
        def uploader(*args,**kwargs):return upload_run(*args,**kwargs,sleep=lambda _:None,now=lambda:1000)
        result=verify.run(saved,None,None,grant,journal,receipt,intent,apply=True,runner=runner,uploader=uploader)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(journal.read()[0]['phase'],'imported')
        self.assertEqual(probe.attempts['cleanup'],0);self.assertIsNotNone(receipt.backend.load())
        repeated=verify.run(saved,None,None,grant,journal,receipt,intent,apply=True,runner=runner,uploader=uploader)
        self.assertEqual(repeated['result'],'UNVERIFIED');self.assertEqual(probe.attempts['notify'],1)
        self.assertEqual(probe.attempts['cleanup'],0)


if __name__=='__main__':unittest.main()
