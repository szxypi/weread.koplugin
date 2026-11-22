import hashlib
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from native_direct_selection_preflight import bind_native_source
from owner_selection_preview import choose


RAW=('<html><body><p>'+''.join('Unique selection paragraph %04d. ' % i for i in range(20))+'</p></body></html>').encode()


class FakeSelection:
    def __init__(self):
        self.calls=0
        row=choose(RAW.decode(),{},'42','37',1)['reference']
        self.payload={'book_id':'42','chapter_uid':'37','selection_preview':{'reference':row,'body':{'bookVersion':7}}}
        self.web=SimpleNamespace(shards={'e_0':'a','e_1':'b','e_3':'c'})
    def current(self):self.calls+=1


class FakeNative:
    def __init__(self):self.calls=[];self.allowed=set();self.archive_url=None
    def request(self,stage,url,body=None,credentials=None):
        self.calls.append((stage,url,body));return {}
    def download(self,url,credentials):
        self.calls.append(('download',url,None));return b'fixture','envelope'


class DirectPreflightTests(unittest.TestCase):
    def setUp(self):
        self.selection=FakeSelection();self.native=FakeNative();self.credentials={'vid':'123'}
        self.model={'format':'epub','version':7,'chapters':[{'uid':37,'free_or_owned':True,'wordCount':100}]}
    def run_case(self,source=RAW,html=True):
        with patch('native_direct_selection_preflight.catalog',return_value=self.model), \
             patch('native_direct_selection_preflight.decode_content_shards',return_value=RAW.decode()), \
             patch('native_direct_selection_preflight.password',return_value='fixture'), \
             patch('native_direct_selection_preflight.read',return_value={'html':html,'source':source}):
            return bind_native_source(self.selection,self.credentials,probe=self.native)
    def test_exact_authorized_chapter_and_source(self):
        result=self.run_case()
        self.assertEqual(result['source_sha256'],hashlib.sha256(RAW).hexdigest())
        self.assertEqual(self.selection.calls,2)
        self.assertEqual([call[0] for call in self.native.calls],['book','catalog','download'])
        self.assertIn('chapters=0%2C37',self.native.archive_url)
        self.assertIn('stopAutoPayWhenBNE=1',self.native.archive_url)
    def test_ineligible_chapter_and_version_fail_before_download(self):
        for mutate in ('not_owned','wrong_version','duplicate','text'):
            with self.subTest(mutate=mutate):
                self.setUp()
                if mutate=='not_owned':self.model['chapters'][0]['free_or_owned']=False
                elif mutate=='wrong_version':self.model['version']=8
                elif mutate=='duplicate':self.model['chapters'].append(dict(self.model['chapters'][0]))
                else:self.model['format']='txt'
                with self.assertRaises(ValueError):self.run_case()
                self.assertNotIn('download',[call[0] for call in self.native.calls])
    def test_source_mismatch_and_text_fail_closed(self):
        for source,html in ((RAW+b' ',True),(RAW,False)):
            with self.subTest(html=html):
                self.setUp()
                with self.assertRaises(ValueError):self.run_case(source,html)


if __name__=='__main__':unittest.main()
