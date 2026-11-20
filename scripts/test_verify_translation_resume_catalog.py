import io
import json
import unittest
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest.mock import patch

import verify_translation_resume_catalog as target


class TranslationResumeCatalogTests(unittest.TestCase):
    def test_shelf_selection_is_bounded_and_unique(self):
        shelf={'books':[{'bookId':'1'},{'bookId':1},{'bookId':'CB_invalid'},
                        {'bookId':True},{'bookId':'2'},{'bookId':'3'},{'bookId':'4'}]}
        self.assertEqual(target.shelf_ids(shelf),['1','2','3'])
        with self.assertRaises(ValueError): target.shelf_ids({'books':{}})

    def test_native_result_rejects_inconsistent_or_unbounded_receipts(self):
        good={'samples':[{'chapters':12,'resumed':True,'kept':True}]}
        self.assertEqual(target.check_result(good,1),good['samples'])
        for row in ({'chapters':12,'resumed':True,'kept':False},
                    {'chapters':0,'resumed':False,'kept':False},
                    {'chapters':2001,'resumed':False,'kept':False},
                    {'chapters':12,'resumed':1,'kept':True},
                    {'chapters':12,'resumed':True,'kept':True,'book_id':'private'}):
            with self.assertRaises(ValueError): target.check_result({'samples':[row]},1)

    def test_real_mode_keeps_private_data_in_memory_and_uses_read_only_routes(self):
        calls=[]
        class Probe:
            def __init__(self): self.report={'stages':[]};self.vid=None;self.book_id=None
            def set_cookie(self,key,value): self.cookie=(key,value)
            def verify_account(self): calls.append('account')
            def close(self): calls.append('close')
            def request(self,stage,url,body=None):
                calls.append(stage)
                if stage=='shelf':
                    self.assert_route(url,target.BASE+'/web/shelf/sync',body,None)
                    return {'books':[{'bookId':'123'}]}
                self.assert_route(url,target.BASE+'/web/book/chapterInfos',body,{'bookIds':['123']})
                if stage not in ('catalog_before','catalog_after'): raise AssertionError('unexpected route')
                return {'data':[{'bookId':'123','updated':[{'chapterUid':1,'title':'private title','wordCount':12}]}]}
            @staticmethod
            def assert_route(url,expected,body,wanted):
                if url!=expected or body!=wanted: raise AssertionError('unexpected request')
        class Store:
            def load(self): return {'vid':'123','cookies':{'wr_skey':'private-cookie'}}
        def run(command,**kwargs):
            self.assertEqual(command,['isolated'])
            payload=json.loads(kwargs['input'])
            self.assertNotIn('private-cookie',json.dumps(payload))
            response={'samples':[{'chapters':1,'resumed':True,'kept':True}]}
            return SimpleNamespace(returncode=0,stdout=target.FRAME+json.dumps(response).encode())
        output=io.StringIO()
        with patch.object(target,'WebSourceProbe',Probe),patch.object(target,'SessionStore',Store),\
                patch.object(target,'state_hash',lambda value:'stable'),patch.object(target.subprocess,'run',run),\
                patch.object(target.resource,'setrlimit'),redirect_stdout(output):
            self.assertEqual(target.main(['--saved-session','--lua-command','isolated']),0)
        result=json.loads(output.getvalue())
        self.assertEqual(result['result'],'READ_ONLY_CHECKED')
        self.assertEqual(result['stable_catalogs'],1)
        self.assertEqual(result['account_data_writes'],0)
        self.assertNotIn('private',output.getvalue().replace('private_catalog_saved',''))
        self.assertEqual(calls,['account','shelf','catalog_before','catalog_after','shelf','account','close'])


if __name__=='__main__': unittest.main()
