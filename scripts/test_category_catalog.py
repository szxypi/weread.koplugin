"""Offline public hierarchy validation; never uses Keychain or upstream HTTP."""
import copy
import io
import json
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch
import verify_category_catalog as probe


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.source=dict(data=[dict(categories=[dict(CategoryId='rising',title='Rising'),
            dict(CategoryId='100',title='Literature',sublist=[dict(categoryId='101',title='Fiction')]),
            dict(CategoryId='rising',title='Duplicate'),dict(CategoryId='audio',title='Audio',type=1),dict(CategoryId='../bad',title='Invalid')])])

    def test_default_offline(self):
        with patch.object(probe,'urlopen') as network,patch('sys.argv',['probe']),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(probe.main(),0)
        network.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_hierarchy_filter_and_whitelist(self):
        self.source['credentials']='discarded';self.source['data'][0]['categories'][0]['private']='discarded'
        result=probe.project(self.source,1000)
        self.assertEqual((len(result['ranks']),len(result['categories'])),(1,1))
        self.assertEqual(result['categories'][0]['children'][0]['id'],'101')
        self.assertNotIn('private',json.dumps(result));self.assertNotIn('credentials',result)

    def test_malformed_error_and_empty(self):
        for value in (None,[],{},dict(data=[]),dict(data={}),dict(data=self.source['data'],errCode=-1),dict(data=self.source['data'],succ=False)):
            with self.subTest(value=value),self.assertRaises(ValueError):probe.project(value)

    def test_shape_and_label_bounds(self):
        for title in (True,{},'x'*4097,'bad\nlabel'):
            with self.subTest(title_type=type(title)),self.assertRaises(ValueError):probe.project(dict(data=[dict(CategoryId='100',title=title)]))
        with self.assertRaises(ValueError):probe.project(dict(data=[dict(categories={})]))
        with self.assertRaises(ValueError):probe.project(dict(data=[False]*(probe.MAX_NODES+1)))

    def test_depth_bound(self):
        source=copy.deepcopy(self.source)
        for _ in range(18):source=dict(data=[dict(categories=source['data'])])
        with self.assertRaises(ValueError):probe.project(source)

    def test_http_failure_hides_body(self):
        with patch('sys.argv',['probe','--online']),patch.object(probe,'urlopen',side_effect=ValueError('private response body')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(probe.main(),1)
        value=json.loads(out.getvalue());self.assertEqual(value['account_data_writes'],0)
        self.assertNotIn('private response',out.getvalue())


if __name__=='__main__': unittest.main()
