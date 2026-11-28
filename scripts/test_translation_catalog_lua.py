import json
import unittest
from types import SimpleNamespace
from verify_translation_catalog_lua import compare,verify_live_access


class TranslationCatalogLuaTests(unittest.TestCase):
    def setUp(self):
        self.sample=dict(book_id='456',info={'bookId':'456'},source={'data':[]},expected=dict(format='epub',version=7,
            chapters=[dict(uid=7,wordCount=1000,translateVersion=0,free_or_owned=True)]))
        self.member={'paying':True}

    def test_catalog_projection_requires_all_fields_and_types(self):
        value=dict(member=True,format='epub',version=7,rows=[dict(uid=7,wordCount=1000,translateVersion=0,free_or_owned=True)])
        def runner(_command,**kwargs):
            self.assertEqual(json.loads(kwargs['input'])['book_id'],'456')
            return SimpleNamespace(returncode=0,stdout=json.dumps(value).encode())
        self.assertEqual(compare(self.sample,self.member,['lua'],runner=runner),(1,1))
        value['rows'][0]['free_or_owned']=1
        with self.assertRaises(ValueError):compare(self.sample,self.member,['lua'],runner=runner)
        value['rows'][0]['free_or_owned']=True;del value['rows'][0]['wordCount']
        with self.assertRaises(ValueError):compare(self.sample,self.member,['lua'],runner=runner)

    def test_live_access_uses_only_private_pipe_and_exact_receipt(self):
        grant={'vid':'123','accessToken':'synthetic','refreshToken':'synthetic','deviceId':'synthetic'}
        output=dict(ok=True,requests=6,version=7,translate_version=0)
        def runner(_command,**kwargs):
            payload=json.loads(kwargs['input']);self.assertEqual(payload['uid'],7)
            self.assertEqual(payload['credentials'],grant)
            return SimpleNamespace(returncode=0,stdout=b'TRANSLATION_ACCESS='+json.dumps(output).encode()+b'\n')
        verify_live_access(self.sample,grant,['lua'],runner=runner)
        output['requests']=5
        with self.assertRaises(ValueError):verify_live_access(self.sample,grant,['lua'],runner=runner)
        self.sample['expected']['chapters'][0]['free_or_owned']=False
        with self.assertRaises(ValueError):verify_live_access(self.sample,grant,['lua'],runner=runner)


if __name__=='__main__':unittest.main()
