from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

import verify_cb_txt_version_fixture as task
from verify_cb_txt_fixture import MARKER


class FakeWeb:
    def __init__(self):
        self.samples=[]; self.cookies={}; self.closed=False
        self.version_fields={'catalog_before':([],[]),'catalog_after':([],[])}
        self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
    def set_cookie(self,key,value): self.cookies[key]=value
    def verify_account(self): return True
    def inspect(self,target): return dict(book_id=target,source_format='web_txt',source=MARKER)
    def close(self): self.closed=True


class TxtVersionFixtureTest(unittest.TestCase):
    def test_categories_preserve_missing_zero_and_conflicting(self):
        for values,expected in (([], 'absent'), ([('version',0)],'zero'), ([('version',7)],'positive'),
                                ([('version',0),('bookVersion',1)],'conflicting'),
                                ([('version',True)],'invalid'), ([('version','0')],'invalid')):
            with self.subTest(expected=expected): self.assertEqual(task.category(values), expected)

    def run_case(self, web=None, native=None, current=lambda _grant: True):
        web=web or FakeWeb(); native=native or [dict(bookId='CB_Synthetic',version=0)]*2
        calls=[]
        class Native:
            def request(self,stage,url,credentials=None):
                calls.append((stage,url,credentials)); return deepcopy(native[len(calls)-1])
        summary={}; saved=dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'synthetic'})
        result=task.inspect_once(saved,{'vid':'900000'},'CB_Synthetic',current,summary,
                                 web_factory=lambda:web,native_factory=Native)
        self.assertTrue(web.closed); return result,summary,calls

    def test_unversioned_and_matched_positive_are_distinct(self):
        result,summary,calls=self.run_case()
        self.assertTrue(result); self.assertEqual(len(calls),2)
        self.assertEqual(summary['native_version_category'],'zero')
        self.assertEqual(summary['catalog_root_version_category'],'absent')
        self.assertFalse(summary['web_and_native_positive_match'])
        web=FakeWeb();web.version_fields={key:([('version',7)],[]) for key in web.version_fields}
        result,summary,_=self.run_case(web,[dict(bookId='CB_Synthetic',version=7)]*2)
        self.assertTrue(result);self.assertTrue(summary['web_and_native_positive_match'])
        self.assertNotIn('CB_Synthetic',json.dumps(summary))

    def test_unstable_catalog_native_or_account_cannot_pass(self):
        web=FakeWeb();web.version_fields['catalog_after']=([('version',7)],[])
        result,summary,calls=self.run_case(web)
        self.assertFalse(result);self.assertEqual(calls,[]);self.assertEqual(summary,{})
        result,summary,calls=self.run_case(native=[dict(bookId='CB_Synthetic',version=0),dict(bookId='CB_Synthetic',version=1)])
        self.assertFalse(result);self.assertEqual(len(calls),2);self.assertEqual(summary,{})
        with self.assertRaises(ValueError): self.run_case(current=lambda _grant:False)

    def test_invalid_source_and_metadata_do_not_return_success(self):
        web=FakeWeb();web.last_checks['catalog_unchanged']=False
        result,summary,calls=self.run_case(web)
        self.assertFalse(result);self.assertEqual(calls,[]);self.assertEqual(summary,{})
        result,summary,calls=self.run_case(native=[dict(bookId='CB_Other',version=0)]*2)
        self.assertFalse(result);self.assertEqual(len(calls),1);self.assertEqual(summary,{})

    def test_offline_does_not_open_credentials_or_send(self):
        with patch.object(task,'SessionStore') as session, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_only_not_yet_ready_catalogs_are_read_again(self):
        delays=[]
        with patch.object(task,'inspect_once',side_effect=[task.CbReadingError('cb_catalog_empty'),True]) as inspect:
            self.assertTrue(task.inspect_fixture({}, {}, 'CB_Synthetic', lambda _:True, {}, sleep=delays.append))
        self.assertEqual(inspect.call_count,2);self.assertEqual(delays,[2])
        with patch.object(task,'inspect_once',side_effect=task.CbReadingError('other')) as inspect:
            with self.assertRaises(task.CbReadingError):
                task.inspect_fixture({}, {}, 'CB_Synthetic', lambda _:True, {}, sleep=lambda _:self.fail('retry'))
        self.assertEqual(inspect.call_count,1)


if __name__ == '__main__': unittest.main()
