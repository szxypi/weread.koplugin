"""Offline selection and search expectations for the real-data UI check."""
from copy import deepcopy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

import verify_owner_shelf_search_ui as task


def source():
    return dict(books=[dict(bookId='11',title='合成书籍',author='合成作者'),
                       dict(bookId='12',title='合成书籍',author='另外作者'),
                       dict(bookId='13',title='其他书籍',author='合成作者'),
                       dict(bookId='MP_WXS_1',title='公众号',author='公众号')],
                archive=[dict(archiveId=7,name='合成分组',bookIds=['11','13','MP_WXS_1']),
                         dict(archiveId=8,name='另一分组',bookIds=['12'])])


class Tests(unittest.TestCase):
    def test_expected_results_bind_real_group_title_author_and_identifier(self):
        value=task.prepare(source())
        self.assertEqual(value['all_ids'],['11','12','13']);self.assertEqual(value['group_ids'],['11','13'])
        self.assertEqual(value['expected_all'],['11']);self.assertEqual(value['expected_group'],[['11'],['11'],[]])
        self.assertTrue(task.matches({'title':'ＳＴＲＡＳＳＥ','author':'作者'},'strasse 作者'))

    def test_duplicate_group_id_or_ambiguous_group_name_is_not_selected(self):
        value=source();value['archive'][1]['archiveId']=7
        with self.assertRaises(ValueError):task.prepare(value)
        value=source();value['archive'][1]['name']='合成分组'
        with self.assertRaises(ValueError):task.prepare(value)

    def test_missing_group_member_or_unknown_author_cannot_create_expected_result(self):
        for change in ('missing','author'):
            value=source()
            if change=='missing':
                value['archive'][0]['bookIds'].append('999');value['archive'].pop()
            else:
                for row in value['books']:row.pop('author',None)
            with self.subTest(change=change),self.assertRaises(ValueError):task.prepare(value)

    def test_offline_mode_does_not_open_session(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_no_match_term_is_not_fabricated(self):
        value=source();value['books'][2]['title']='KOReaderNoSuchShelfBook0123456789'
        with self.assertRaises(ValueError):task.prepare(value)


if __name__=='__main__':unittest.main()
