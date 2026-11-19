"""Offline scope, projection and guarded-hook checks for Web bookmark readback."""
import base64
from copy import deepcopy
import hashlib
import unittest
from unittest.mock import Mock

from cb_txt_padded_bookmark_trial import BODY,prepare
from test_cb_txt_highlight_trial import sample
from test_secure_native_session import Backend
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_bookmark_cross_channel as verify


class CrossChannelTests(unittest.TestCase):
    def setUp(self):
        source,baseline,_,_=sample();source['source']=BODY.decode();source['source_raw_sha256']=hashlib.sha256(BODY).hexdigest()
        _plan,self.body=prepare('900000',source['book_id'],'a'*32,source,0,baseline)
        self.target=dict(id='synthetic-new',sha256='a'*64)
        self.row=dict(bookmarkId=self.target['id'],type=0,chapterUid=2,range=self.body['range'],markText=self.body['markText'])
        self.payload=dict(book=source['book_id'],chapter='2',source=source['source'],first=48,owner='900000',cookies={'wr_vid':'900000'})
        self.expected=dict(result='WEB_READBACK',stable=True,single_new_record=True,point_type=True,chapter_matches=True,range_matches=True,preview_matches=True)

    def test_web_projection_checks_identity_scope_and_both_preview_encodings(self):
        plain=verify.compare({'updated':[self.row]},self.payload['book'],self.body,self.target)
        self.assertTrue(all(plain.values()))
        encoded=deepcopy(self.row);encoded['markText']=base64.b64encode(self.row['markText'].encode()).decode()
        self.assertTrue(all(verify.compare({'updated':[encoded]},self.payload['book'],self.body,self.target).values()))
        for change,field in (({'type':1},'point_type'),({'chapterUid':3},'chapter_matches'),({'range':'47'},'range_matches'),({'markText':'other'},'preview_matches')):
            self.assertFalse(verify.compare({'updated':[dict(self.row,**change)]},self.payload['book'],self.body,self.target)[field])
        self.assertFalse(verify.compare({'updated':[self.row,dict(self.row,bookmarkId='other')]},self.payload['book'],self.body,self.target)['single_new_record'])
        for bad in ({'updated':[]},{'updated':[self.row],'hasMore':1},{'updated':[self.row],'bookId':'CB_Other'},{'updated':[self.row],'errcode':-1}):
            with self.assertRaises(ValueError):verify.compare(bad,self.payload['book'],self.body,self.target)

    def test_web_guard_accepts_only_exact_target_gets(self):
        web=verify.BookmarkWeb(self.payload['book']);web.authenticated=True
        url='https://weread.qq.com/web/book/bookmarklist?bookId='+self.payload['book']
        web.guard('bookmarks_before',url,None);web.guard('bookmarks_after',url,None)
        with self.assertRaises(ValueError):web.guard('bookmarks_after',url,None)
        for other,body in ((url+'&extra=1',None),(url,{}),(url.replace(self.payload['book'],'CB_Other'),None)):
            candidate=verify.BookmarkWeb(self.payload['book']);candidate.authenticated=True
            with self.assertRaises(ValueError):candidate.guard('bookmarks_before',other,body)

    def test_independent_web_readback_must_be_stable_and_same_owner(self):
        class Web:
            def __init__(inner,_book):inner.reads=0
            def set_cookie(inner,*_):pass
            def verify_account(inner):pass
            def close(inner):pass
            def request(inner,_stage,_url):inner.reads+=1;return {'updated':[deepcopy(self.row)]}
        self.assertEqual(verify.observe_web(self.payload,self.body,self.target,factory=Web),self.expected)
        with self.assertRaises(ValueError):verify.observe_web(dict(self.payload,owner='800000'),self.body,self.target,factory=Web)
        class Changing(Web):
            def request(inner,*_):
                inner.reads+=1;return {'updated':[dict(self.row,range='48' if inner.reads==1 else '47')]}
        with self.assertRaises(ValueError):verify.observe_web(self.payload,self.body,self.target,factory=Changing)

    def test_web_error_never_prevents_cleanup_or_claims_success(self):
        receipt=Receipt(Backend());calls=[]
        def native_ui(*_args,armed,on_created,**_kwargs):
            calls.append(armed)
            if armed:on_created(self.payload,self.body,self.target)
            return {'result':'PASS' if armed else 'DRY_RUN'}
        def runner(*_args,**kwargs):
            ui=kwargs['ui_runner'];ui(armed=False);ui(armed=True)
            return {'result':'CB_NATIVE_TXT_PADDED_BOOKMARK_VERIFIED','fixture_removed':True}
        good=verify.run({},None,None,{},object(),receipt,object(),['synthetic'],apply=True,runner=runner,native_ui=native_ui,web_observer=Mock(return_value=self.expected))
        self.assertEqual(good['result'],'CB_TXT_BOOKMARK_CROSS_CHANNEL_VERIFIED');self.assertEqual(calls,[False,True])
        self.assertFalse(good['official_saved_bookmark_display_verified']);calls.clear()
        failure=verify.run({},None,None,{},object(),receipt,object(),['synthetic'],apply=True,runner=runner,native_ui=native_ui,web_observer=Mock(side_effect=ValueError('private detail')))
        self.assertEqual(failure['result'],'CB_TXT_BOOKMARK_CROSS_CHANNEL_UNVERIFIED');self.assertTrue(failure['fixture_removed'])
        self.assertNotIn('private detail',str(failure));self.assertEqual(calls,[False,True])


if __name__=='__main__':unittest.main()
