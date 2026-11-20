"""Independent comparison and default-offline boundary for note export."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

import verify_cloud_notes_export as task


class VerifyCloudNotesExportTests(unittest.TestCase):
    def fixture(self):
        marks={'fetched_at':1000,'chapters':[{'chapterUid':2,'title':'Synthetic chapter'}],
               'updated':[{'bookmarkId':'private-id','type':1,'chapterUid':2,'markText':'Quote\r\n<script> [link](x)',
                           'abstract':'Different excerpt','style':1,'colorStyle':3,'range':'1-2'}]}
        thoughts={'fetched_at':1001,'reviews':[{'reviewId':'private-thought','content':'Synthetic thought',
                   'abstract':'Quoted text','isPrivate':1,'chapterUid':2,'chapterName':''}]}
        left,right=task.expected_rows(marks,thoughts)
        markdown=''.join(task.quoted(value) for value in ('Quote\r\n<script> [link](x)','Different excerpt','Quoted text','Synthetic thought'))
        exported={'schema':1,'source':'WeRead','book':{'title':'Synthetic export','author':'','exported_at':'synthetic'},
                  'snapshots':{'marks':{'available':True,'fetched_at':1000},'thoughts':{'available':True,'fetched_at':1001}},
                  'marks':left,'thoughts':right}
        return marks,thoughts,{'result':'PASS','count':2,'json':exported,'markdown':markdown}

    def test_default_never_loads_credentials_or_runs_a_process(self):
        with patch.object(task,'SessionStore') as session,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_exact_json_and_markdown_comparison(self):
        marks,thoughts,value=self.fixture()
        raw=task.FRAME+json.dumps(value).encode()
        self.assertEqual(task.compare(raw,marks,thoughts),(1,1))
        self.assertEqual(value['json']['thoughts'][0]['chapter'],'')
        for mode in ('missing_quote','wrong_count','wrong_visibility','extra_identifier','private_book_field','wrong_snapshot'):
            changed=deepcopy(value)
            if mode=='missing_quote':changed['markdown']='unrelated'
            elif mode=='wrong_count':changed['count']=True
            elif mode=='wrong_visibility':changed['json']['thoughts'][0]['visibility']='public'
            elif mode=='extra_identifier':changed['json']['marks'][0]['bookmarkId']='private-id'
            elif mode=='private_book_field':changed['json']['book']['book_id']='private'
            else:changed['json']['snapshots']['thoughts']['available']=False
            with self.subTest(mode=mode),self.assertRaises(ValueError):
                task.compare(task.FRAME+json.dumps(changed).encode(),marks,thoughts)
        with self.assertRaises(ValueError):task.compare(b'missing',marks,thoughts)


if __name__=='__main__':unittest.main()
