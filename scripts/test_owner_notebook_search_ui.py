"""Private result boundaries for notebook multiword UI validation."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from owner_notebook_search_cases import prepare
from run_notebook_catalog_ui import FLAGS,FRAME,validate_stage
import verify_owner_notebook_search_ui as task


def snapshot():
    return dict(schema=1,fetched_at=1,books=[dict(bookId='11',title='合成书籍',author='合成作者'),
        dict(bookId='12',title='合成书籍',author='另一作者')])


def response():
    stage=dict.fromkeys(FLAGS,True)
    stage.update(result='PASS',mode='live',phase='complete',pages=1,books=2,requests=1,forbidden=0,failed_line=0,owner_search=True)
    return dict(model=snapshot(),native=snapshot(),requests=1,ui=dict(result='PASS',profile_removed=True,
        installed_bytes_match=True,installed_files=10,stages=[stage,dict(stage,mode='reopen',requests=0)]))


def child(value,code=0):return SimpleNamespace(returncode=code,stdout=FRAME+json.dumps(value).encode())


class Tests(unittest.TestCase):
    def test_cases_match_title_author_identifier_and_empty_result(self):
        cases=prepare(snapshot());self.assertEqual(len(cases),3)
        self.assertEqual([row['expected'] for row in cases],[['11'],['11'],[]])
        self.assertNotIn('11',repr({'result':'PASS','cases':len(cases)}))

    def test_no_eligible_or_known_missing_term_rejects(self):
        for data in (dict(books=[]),dict(books=[dict(bookId='11',title='one word',author='')]),
                     dict(books=[dict(bookId='11',title='合成书籍',author='合成作者'),
                                 dict(bookId='12',title='KOReaderNoSuchNotebook0123456789',author='作者')])):
            with self.subTest(data=data),self.assertRaises(ValueError):prepare(data)

    def test_owner_stage_requires_search_and_offline_restart(self):
        stage=response()['ui']['stages'][0];validate_stage(stage,'live',2,owner_search=True)
        for change in ({'owner_search':False},{'requests':0},{'forbidden':1}):
            with self.assertRaises(ValueError):validate_stage(dict(stage,**change),'live',2,owner_search=True)
        with self.assertRaises(ValueError):validate_stage(stage,'live',2)

    def test_only_exact_profile_cleanup_and_expected_content_is_accepted(self):
        value=response();self.assertTrue(task.verify_response(child(value),snapshot()))
        for update in ({'requests':0},{'native':dict(snapshot(),books=[])},
                       {'ui':dict(value['ui'],profile_removed=False)}, {'ui':dict(value['ui'],installed_bytes_match=False)}):
            with self.subTest(update=update),self.assertRaises(ValueError):task.verify_response(child(dict(value,**update)),snapshot())
        with self.assertRaises(ValueError):task.verify_response(child(value,1),snapshot())

    def test_offline_default_does_not_access_account(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
