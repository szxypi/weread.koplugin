#!/usr/bin/env python3
"""Offline translation preflight boundaries; no live requests or credentials."""
import copy
import unittest
from verify_eink_login import BASE
from verify_translation_preflight import PLATFORM,TranslationError,TranslationProbe,TranslationWebProbe,catalog,catalog_body,flag,membership,content_summary,save_refreshed_web_session


class TranslationPreflightTest(unittest.TestCase):
    def setUp(self):
        self.info=dict(bookId='900001',format='epub',version=12)
        self.raw=dict(data=[dict(bookId='900001',updated=[
            dict(chapterUid=0,wordCount=0,price=0,paid=0),
            dict(chapterUid=1,wordCount=1200,price=0,paid=0,hasTranslated=1,translateVersion=2,transWordCount=1000),
            dict(chapterUid=2,wordCount=1200,price=-1,paid=0),
            dict(chapterUid=3,wordCount=1200,price=99,paid=1)])])
    def project(self): return catalog(self.raw,'900001',self.info)
    def test_member_flags_explicit(self):
        for value in (True,1,'1','true'): self.assertTrue(membership(dict(isPaying=value))['paying'])
        for value in (False,0,'0','false'): self.assertFalse(membership(dict(isPaying=value))['paying'])
        for value in (None,2,-1,{},[],1.0,'yes'):
            with self.subTest(value=value),self.assertRaises(TranslationError): flag(value)
        with self.assertRaises(TranslationError): membership({})
    def test_full_catalog_read_shape(self):
        self.assertEqual(catalog_body('900001'),dict(bookIds=['900001'],synckeys=[0],updateTimes=[0],maxfreeIdx=[0]))
        with self.assertRaises(TranslationError): catalog_body('MP_WXS_1')
    def test_project_preserves_only_known_fields(self):
        self.raw['data'][0]['updated'][1]['private']='discard'
        out=self.project()
        self.assertEqual((out['book_id'],out['format'],out['version']),('900001','epub',12))
        self.assertNotIn('private',out['chapters'][1]);self.assertTrue(out['chapters'][1]['hasTranslated'])
        self.assertEqual(out['chapters'][1]['translateVersion'],2)
    def test_negative_or_unknown_price_does_not_mean_free(self):
        out=self.project()['chapters']
        self.assertFalse(out[2]['free_or_owned']);self.assertFalse(out[2]['price_known'])
        self.assertTrue(out[1]['free_or_owned']);self.assertTrue(out[3]['free_or_owned'])
        self.raw['data'][0]['updated'][2].pop('price')
        self.assertFalse(self.project()['chapters'][2]['free_or_owned'])
    def test_member_flag_does_not_override_chapter_price(self):
        self.assertTrue(membership(dict(isPaying=1))['paying'])
        self.assertFalse(self.project()['chapters'][2]['free_or_owned'])
    def test_absent_translation_fields_stay_unknown(self):
        row=self.project()['chapters'][2]
        for field in ('hasTranslated','translateVersion','transWordCount'): self.assertNotIn(field,row)
    def test_missing_or_wrong_catalog_owner_rejected(self):
        for raw in ({},dict(data=[]),dict(data=[dict(bookId='900002',updated=[])]),dict(data=self.raw['data']*2)):
            with self.subTest(raw=raw),self.assertRaises(TranslationError): catalog(raw,'900001',self.info)
        with self.assertRaises(TranslationError): catalog(self.raw,'900001',dict(self.info,bookId='900002'))
        self.raw['data'][0]['book']=dict(bookId='900002')
        with self.assertRaises(TranslationError): self.project()
    def test_duplicate_chapter_rejected(self):
        self.raw['data'][0]['updated'].append(copy.deepcopy(self.raw['data'][0]['updated'][1]))
        with self.assertRaises(TranslationError): self.project()
    def test_invalid_numeric_fields_rejected(self):
        for field,value in [('wordCount',True),('translateVersion',-1),('transWordCount',float('nan')),('paid',False),('price',False),('price',float('inf'))]:
            self.setUp();self.raw['data'][0]['updated'][1][field]=value
            with self.subTest(field=field,value=value),self.assertRaises(TranslationError): self.project()
    def test_unknown_format_not_supported(self):
        self.info['format']='mobi'
        with self.assertRaises(TranslationError): self.project()
    def test_guard_rejects_get_mode_change_and_generation(self):
        probe=TranslationProbe();probe.allowed_ids={'900001'}
        bad=[('mode',BASE+'/trans/pdfepub?cbid=900001&transFormat=epubTranslate&transType=epubTranslate',None),
            ('generation',BASE+'/en/bookread',dict(bookId='900001',freeTrial=0)),
            ('trial',BASE+'/pay/memberCardSummary',dict(freeTrial=1)),
            ('book',BASE+'/book/info?bookId=900002',None),
            ('catalog',BASE+'/book/chapterInfos',dict(bookIds=['900001'])),
            ('catalog','http://i.weread.qq.com/book/chapterInfos',catalog_body('900001')),
            ('member',BASE+'/pay/memberCardSummary?pf='+PLATFORM+'#x',None)]
        for stage,url,body in bad:
            with self.subTest(stage=stage),self.assertRaises(TranslationError): probe.guard(stage,url,body)
    def test_guard_accepts_only_known_catalog_read(self):
        probe=TranslationProbe();probe.allowed_ids={'900001'}
        probe.guard('catalog',BASE+'/book/chapterInfos',catalog_body('900001'))
        probe.guard('member',BASE+'/pay/memberCardSummary?pf='+PLATFORM,None)
        with self.assertRaises(TranslationError): probe.guard('catalog',BASE+'/book/chapterInfos',catalog_body('900002'))
    def test_translated_text_requires_real_text(self):
        value=content_summary('<p class="wr-translation"><script>ignored</script><img src="x"/> &nbsp;</p>')
        self.assertEqual(value,dict(translation_blocks=1,nonempty_translation_blocks=0))
        value=content_summary('<p class="wr-translation">译文 <span>更多</span></p><p class="wr-translation">第二段</p>')
        self.assertEqual(value,dict(translation_blocks=2,nonempty_translation_blocks=2))
    def test_nested_translation_not_counted_twice(self):
        value=content_summary('<div class="wr-translation">译文 <p class="wr-translation">嵌套</p></div>')
        self.assertEqual(value,dict(translation_blocks=1,nonempty_translation_blocks=1))
    def test_original_or_bare_class_is_not_translation(self):
        self.assertEqual(content_summary('<p class>Original text</p>')['translation_blocks'],0)
        self.assertEqual(content_summary('<p data-class="wr-translation">Original text</p>')['translation_blocks'],0)
    def test_content_size_and_depth_bounds(self):
        for source in ('','x'*(2*1024*1024+1),'<div>'*257+'x'+'</div>'*257):
            with self.subTest(size=len(source)),self.assertRaises(TranslationError): content_summary(source)
    def test_web_guard_blocks_account_writes_and_modified_content(self):
        from verify_web_source_progress import BASE as WEB_BASE
        from fetch_weread_epub import make_content_params
        probe=TranslationWebProbe();probe.authenticated=True;probe.book_id='900001';probe.chapter='1'
        probe.fields=make_content_params('900001','1','synthetic-session')
        probe.guard('e_0',WEB_BASE+'/web/book/chapter/e_0',probe.fields.copy())
        for stage,url,body in [('read',WEB_BASE+'/web/book/read',{}),('e_0',WEB_BASE+'/web/book/chapter/e_0',dict(probe.fields,sc=0))]:
            with self.subTest(stage=stage),self.assertRaises(TranslationError): probe.guard(stage,url,body)
        probe.fields=dict(probe.fields,freeTrial=1)
        with self.assertRaises(TranslationError): probe.guard('e_0',WEB_BASE+'/web/book/chapter/e_0',probe.fields)
        probe.close()
    def session_fixture(self,rotated=False):
        from types import SimpleNamespace
        saved=dict(vid='900000',cookies=dict(wr_skey='synthetic-before'))
        probe=SimpleNamespace(authenticated=True,vid='900000',cookies=[
            SimpleNamespace(name='wr_skey',value='synthetic-after' if rotated else 'synthetic-before',domain='.weread.qq.com',path='/'),
            SimpleNamespace(name='wr_skey',value='ignore-foreign',domain='example.invalid',path='/')])
        class Store:
            calls=0
            current=saved
            def load(self): return self.current
            def save(self,value): self.calls+=1;self.probe=value
        return Store(),saved,probe
    def test_unchanged_or_foreign_cookie_does_not_write_keychain(self):
        store,saved,probe=self.session_fixture()
        self.assertFalse(save_refreshed_web_session(store,saved,probe));self.assertEqual(store.calls,0)
    def test_verified_cookie_refresh_retained(self):
        store,saved,probe=self.session_fixture(True)
        self.assertTrue(save_refreshed_web_session(store,saved,probe));self.assertEqual(store.calls,1)
        self.assertIs(store.probe,probe)
    def test_changed_owner_or_record_cannot_save_old_session(self):
        from secure_weread_session import StoreError
        for change in ('owner','authenticated','record'):
            store,saved,probe=self.session_fixture(True)
            if change=='owner': probe.vid='900001'
            elif change=='authenticated': probe.authenticated=False
            else: store.current=dict(saved,vid='900001')
            with self.subTest(change=change),self.assertRaises(StoreError): save_refreshed_web_session(store,saved,probe)
            self.assertEqual(store.calls,0)
    def test_sample_bound_checked_before_http(self):
        probe=TranslationProbe()
        for limit in (0,4,True):
            with self.subTest(limit=limit),self.assertRaises(TranslationError): probe.inspect({},limit)
        self.assertEqual(probe.report['stages'],[])


if __name__=='__main__': unittest.main()
