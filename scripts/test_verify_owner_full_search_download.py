import contextlib,io,json,unittest
from unittest.mock import patch

import verify_owner_full_search_download as task


class OwnerFullSearchTests(unittest.TestCase):
    def test_offline_default_does_not_touch_session(self):
        with patch.object(task,'SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_catalog_is_bounded_unique_and_contains_only_safe_fields(self):
        rows=[{'chapterUid':1,'title':'private','chapterIdx':4,'wordCount':12,'extra':'private'},
              {'chapterUid':'2','title':'private','wordCount':20}]
        self.assertEqual(task.safe_chapters(rows),[{'chapterUid':'1','title':'章节 1','chapterIdx':4,'wordCount':12},
                                                   {'chapterUid':'2','title':'章节 2','wordCount':20}])
        for bad in ([],[rows[0]],rows+[rows[0]],[rows[0],{'chapterUid':'0'}],
                    [rows[0],{'chapterUid':'2147483648'}],[rows[0],{'chapterUid':'2/unsafe'}]):
            with self.assertRaises(ValueError):task.safe_chapters(bad)

    def test_attestation_failure_occurs_before_session(self):
        with patch.object(task,'trusted_command',side_effect=ValueError('private failure')),\
             patch.object(task,'SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main(['--saved-session']),1)
        store.assert_not_called();self.assertNotIn('private failure',output.getvalue())


if __name__=='__main__':unittest.main()
