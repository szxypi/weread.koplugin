from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from verify_eink_login import NativeProbe
from verify_notebook_catalog import Probe, main, summarize
from notebook_catalog_model import project


class NotebookCatalogTest(unittest.TestCase):
    def test_offline_default_has_no_network_or_keychain(self):
        with patch('verify_notebook_catalog.SessionStore') as store,patch('verify_notebook_catalog.Probe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();probe.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_fixed_read_only_requests_and_bounded_cursor(self):
        probe=Probe();grant={'vid':'synthetic'}
        with patch.object(NativeProbe,'request',return_value={'books':[]}) as request:
            probe.read(grant,2);probe.read(grant,100);probe.read(grant,2,123)
            self.assertEqual(request.call_count,3)
            self.assertEqual(request.call_args.args[1],'https://i.weread.qq.com/user/notebooks?count=2&lastSort=123')
            self.assertIsNone(request.call_args.kwargs.get('body'))
            with self.assertRaises(ValueError):probe.read(grant,2)
        for count,last in ((1,None),(2,-1),(2,True),(2,'1'),(2,2**54)):
            with self.subTest(count=count,last=last),self.assertRaises(ValueError):Probe().read(grant,count,last)

    def test_shape_contains_no_book_data(self):
        value={'books':[{'bookId':'private-book','noteCount':1,'book':{'title':'private-title'}}],
               'hasMore':1,'totalBookCount':1}
        result=summarize(value)
        self.assertEqual(result['rows'],1);self.assertEqual(result['book_fields']['title'],1)
        self.assertNotIn('private-book',repr(result));self.assertNotIn('private-title',repr(result))
        for invalid in ({}, {'books':[None]}, {'books':[{}]*5001}):
            with self.assertRaises(ValueError):summarize(invalid)

    def test_full_catalog_projection_rejects_partial_and_conflicting_rows(self):
        row=dict(bookId='CB_example',book=dict(bookId='CB_example',title='Synthetic',author='Author',token='discard'),
                 noteCount=2,reviewCount=1,bookmarkCount=0,sort=10,token='discard')
        source=dict(books=[row],totalBookCount=1,synckey=100)
        projected=project(source,1000)
        self.assertEqual(projected['books'][0]['bookId'],'CB_example')
        self.assertNotIn('discard',repr(projected))
        for changed in (dict(source,totalBookCount=2),dict(source,hasMore=1),dict(source,books=[row,row],totalBookCount=2),
                        dict(source,books=[dict(row,bookId='42')]),dict(source,books=[dict(row,noteCount=True)])):
            with self.subTest(changed=changed),self.assertRaises(ValueError):project(changed,1000)
        self.assertEqual(project(dict(books=[],totalBookCount=0),1000)['books'],[])


if __name__=='__main__':unittest.main()
