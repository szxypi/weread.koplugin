"""Offline scope, privacy and projection checks for CB source freshness."""
from contextlib import redirect_stdout
import copy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import verify_cb_guarded_currentness as task


class TestCbSourceCurrentness(unittest.TestCase):
    def setUp(self):
        self.sample=dict(book_id='CB_Synthetic',chapter_uid='11',source_format='web_xhtml',source='synthetic source',
                         source_raw_sha256='a'*64,chapters=[dict(chapterUid=11,chapterIdx=0)])
        self.point=dict(kind='located',chapter_uid='11',chapter_idx=0)

    def test_offline_does_not_access_session_or_process(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'compare') as compare,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();compare.assert_not_called()
        report=json.loads(out.getvalue());self.assertEqual(report['result'],'OFFLINE_ONLY')
        self.assertEqual(report['account_data_writes'],0);self.assertFalse(report['write_authority_granted'])

    def test_descriptor_requires_unique_exact_catalog_index(self):
        value=task.descriptor(self.sample,self.point)
        self.assertEqual(value['chapter_idx'],0);self.assertEqual(value['raw_bytes'],len(self.sample['source']))
        for change in (dict(source_format='web_txt'),dict(chapter_uid='12'),dict(chapters=[]),
                       dict(chapters=[dict(chapterUid=11,chapterIdx=0),dict(chapterUid=11,chapterIdx=0)]),
                       dict(chapters=[dict(chapterUid=11,chapterIdx=1)]),dict(chapters=[dict(chapterUid=11,chapterIdx=True)])):
            with self.subTest(change=change):self.assertIsNone(task.descriptor(dict(self.sample,**change),self.point))
        bad=copy.deepcopy(self.sample);bad['chapters'][0]['chapterId']=12
        self.assertIsNone(task.descriptor(bad,self.point))

    def test_private_payload_is_only_on_pipe_and_result_is_strict(self):
        expected=task.descriptor(self.sample,self.point);saved=dict(vid='900000',cookies={'wr_skey':'synthetic-private'})
        good=dict(matched=True,requests=10,upload_disabled=True,numeric_gate_preserved=True)
        response=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_CB_GUARDED_CURRENTNESS='+json.dumps(good).encode())
        with patch.object(task.subprocess,'run',return_value=response) as child:
            self.assertTrue(task.compare(['synthetic'],expected,{'chapter_offset':1},saved))
        self.assertNotIn('synthetic-private',' '.join(child.call_args.args[0]))
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['cookies'],saved['cookies'])
        for changed in (dict(good,requests=11),dict(good,upload_disabled=False),dict(good,private='not-allowed')):
            response=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_CB_GUARDED_CURRENTNESS='+json.dumps(changed).encode())
            with patch.object(task.subprocess,'run',return_value=response),self.assertRaises(ValueError):
                task.compare(['synthetic'],expected,{'chapter_offset':1},saved)


if __name__=='__main__':unittest.main()
