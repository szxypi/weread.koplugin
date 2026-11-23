"""Catalog projection and private, opt-in verification boundary."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import subprocess
import unittest
from unittest.mock import patch
import verify_native_book_catalog as task


def fixture():
    info=dict(bookId='456',format='epub',version=7)
    raw=dict(data=[dict(bookId='456',updated=[
        dict(chapterUid=0,title='Cover',wordCount=0,price=0),
        dict(chapterUid=7,title='A',chapterIdx=1,wordCount=10,price=0),
        dict(chapterUid=8,title='B',chapterIndex='2',wordCount=20,price=2,paid=1),
        dict(chapterUid=9,title='C',wordCount=30,price=2)])])
    return raw,info


class VerifyNativeCatalogTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                patch.object(task.subprocess,'run') as runner,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        saved.assert_not_called();native.assert_not_called();runner.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_projection_rejects_wrong_order_and_redacts_input(self):
        raw,info=fixture();expected=task.expected(raw,'456',info)
        self.assertEqual([r['chapterUid'] for r in expected['chapters']],['7','8','9'])
        self.assertEqual([r['downloadable'] for r in expected['chapters']],[True,True,False])
        self.assertTrue(all(row['wordCountKnown'] for row in expected['chapters']))
        def runner(_command,**kwargs):
            self.assertEqual(json.loads(kwargs['input'])['book_id'],'456')
            return subprocess.CompletedProcess([],0,task.FRAME+json.dumps(expected).encode()+b'\n')
        self.assertEqual(task.compare(raw,'456',info,['fake'],runner),(3,2))
        bad=deepcopy(expected);bad['chapters'].reverse()
        def changed(_command,**_kwargs):return subprocess.CompletedProcess([],0,task.FRAME+json.dumps(bad).encode())
        with self.assertRaises(ValueError):task.compare(raw,'456',info,['fake'],changed)

    def test_invalid_display_does_not_become_a_reading_catalog(self):
        for bad in (True,-1,'01',1000001):
            raw,info=fixture();raw['data'][0]['updated'][1]['chapterIdx']=bad
            with self.subTest(bad=bad),self.assertRaises(ValueError):task.expected(raw,'456',info)
        raw,info=fixture();raw['data'][0]['updated'][1]['chapterIndex']=2
        with self.assertRaises(ValueError):task.expected(raw,'456',info)

    def test_missing_word_count_is_not_a_known_zero(self):
        raw,info=fixture();del raw['data'][0]['updated'][1]['wordCount']
        row=task.expected(raw,'456',info)['chapters'][0]
        self.assertEqual(row['wordCount'],0)
        self.assertIs(row['wordCountKnown'],False)


if __name__=='__main__':unittest.main()
