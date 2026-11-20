#!/usr/bin/env python3
"""Offline scope and source checks for native TXT private thoughts."""
import unittest

from test_cb_txt_highlight_trial import sample
from test_secure_native_session import Backend
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_selection_native as verify


class NativeTxtThoughtTests(unittest.TestCase):
    def test_wrapper_binds_zero_version_utf16_and_receipt(self):
        source,baseline,_,_=sample();receipt=Receipt(Backend());seen=[]
        def runner(*_args,**kwargs):
            self.assertEqual(kwargs['source_format'],'web_txt');self.assertTrue(kwargs['allow_zero_version'])
            plan,context,body=kwargs['prepare_fn']('900000',source['book_id'],'a'*32,source,0,baseline,'b'*32)
            self.assertEqual((context['range'],context['bookVersion']),('48-110',0))
            self.assertEqual(kwargs['span_fn'](source['source'],source['book_id'],'2',
                dict(chapterUid=2,range=context['range'],markText=context['abstract']))['first'],48)
            self.assertNotIn(body['abstract'],str(plan));seen.append(True)
            return dict(result='READ_ONLY_PREVIEW')
        result=verify.run({},None,None,{},object(),receipt,object(),['native'],runner=runner)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertEqual(seen,[True])
        receipt.backend.save(b'prior')
        with self.assertRaises(ValueError):verify.run({},None,None,{},object(),receipt,object(),['native'],runner=runner)


if __name__=='__main__':unittest.main()
