#!/usr/bin/env python3
"""Offline checks for the isolated TXT bookmark verifier."""
import hashlib
import unittest

import cb_txt_bookmark_trial as trial
from test_cb_txt_highlight_trial import sample
from test_secure_native_session import Backend
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_bookmark_native as verify


class NativeTxtBookmarkTests(unittest.TestCase):
    def test_utf16_point_and_bom(self):
        source,baseline,_,_=sample();source['source']=trial.BODY.decode();source['source_raw_sha256']=hashlib.sha256(trial.BODY).hexdigest()
        _plan,body=trial.prepare('900000',source['book_id'],'a'*32,source,0,baseline)
        point=verify.point(source['source'],source['book_id'],source['chapter_uid'],body)
        self.assertEqual(point,dict(chapter_offset=48))
        self.assertEqual(verify.point('\ufeff'+source['source'],source['book_id'],source['chapter_uid'],body),dict(chapter_offset=49))
        with self.assertRaises(ValueError):verify.point(source['source'],source['book_id'],'3',body)
        with self.assertRaises(ValueError):verify.point(source['source'],source['book_id'],source['chapter_uid'],dict(body,range='47'))
        with self.assertRaises(ValueError):verify.point(source['source'],source['book_id'],source['chapter_uid'],dict(body,markText='incorrect'))

    def test_wrapper_binds_fixture_and_receipt(self):
        source,baseline,_,_=sample();source['source']=trial.BODY.decode();source['source_raw_sha256']=hashlib.sha256(trial.BODY).hexdigest();receipt=Receipt(Backend());seen=[]
        def runner(*_args,**kwargs):
            self.assertEqual(kwargs['source_format'],'web_txt');self.assertTrue(kwargs['allow_zero_version'])
            plan,body=kwargs['prepare_fn']('900000',source['book_id'],'a'*32,source,0,baseline)
            self.assertEqual(kwargs['point_fn'](source['source'],source['book_id'],'2',body)['chapter_offset'],48)
            self.assertNotIn(body['markText'],str(plan));seen.append(True)
            return dict(result='READ_ONLY_PREVIEW')
        self.assertEqual(verify.run({},None,None,{},object(),receipt,object(),['native'],runner=runner)['result'],'READ_ONLY_PREVIEW')
        self.assertEqual(seen,[True]);receipt.backend.save(b'prior')
        with self.assertRaises(ValueError):verify.run({},None,None,{},object(),receipt,object(),['native'],runner=runner)

    def test_rejects_changed_fixture_hash(self):
        plan=dict(owner='900000',name='KOReaderSynthetic-0123456789abcdef.txt',count=0,
                  body_sha256=hashlib.sha256(trial.BODY).hexdigest(),members_sha256='a'*64,
                  flags_sha256='b'*64,groups_sha256='c'*64,grant_sha256='d'*64)
        self.assertIs(verify.validate_plan(plan),plan)
        with self.assertRaises(ValueError):verify.validate_plan(dict(plan,body_sha256='0'*64))


if __name__=='__main__':unittest.main()
