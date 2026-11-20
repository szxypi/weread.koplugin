#!/usr/bin/env python3
"""Offline scope and independent UTF-16 checks for native TXT writes."""
import unittest

from test_cb_txt_highlight_trial import sample
from test_secure_native_session import Backend
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_highlight_native as verify


class NativeTxtHighlightTests(unittest.TestCase):
    def test_utf16_span_distinguishes_scalar_range_and_bom(self):
        source,baseline,_,_=sample()
        from cb_txt_highlight_trial import prepare
        _plan,body=prepare('900000',source['book_id'],'a'*32,source,1,baseline,range_unit='utf16')
        span=verify.span(source['source'],source['book_id'],source['chapter_uid'],body)
        self.assertEqual(span,dict(first=48,last=110))
        with self.assertRaises(ValueError):verify.span(source['source'],source['book_id'],'3',body)
        with self.assertRaises(ValueError):verify.span(source['source'],source['book_id'],source['chapter_uid'],dict(body,range='47-109'))
        self.assertEqual(verify.span('\ufeff'+source['source'],source['book_id'],source['chapter_uid'],body),dict(first=49,last=111))

    def test_wrapper_binds_txt_prepare_and_receipt(self):
        source,baseline,_,_=sample();receipt=Receipt(Backend());seen=[]
        def runner(*_args,**kwargs):
            self.assertEqual(kwargs['source_format'],'web_txt')
            plan,body=kwargs['prepare_fn']('900000',source['book_id'],'a'*32,source,1,baseline)
            self.assertEqual(body['range'],'48-110');self.assertNotIn(body['markText'],str(plan))
            self.assertEqual(kwargs['span_fn'](source['source'],source['book_id'],'2',body)['first'],48)
            seen.append(True);return dict(result='READ_ONLY_PREVIEW')
        result=verify.run({},None,None,{},object(),receipt,object(),['native'],runner=runner)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertEqual(seen,[True])
        receipt.backend.save(b'prior')
        with self.assertRaises(ValueError):verify.run({},None,None,{},object(),receipt,object(),['native'],runner=runner)


if __name__=='__main__':unittest.main()
