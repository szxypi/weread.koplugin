"""Pure source-bound positive-time payload checks; no network."""
import copy
import unittest
from unittest.mock import patch
from cb_fixture_web_time import build,validate
from fetch_weread_epub import sorted_query,weread_sign
from test_cb_fixture_position import fixture
from cb_fixture_position import plan


class FixtureWebTime(unittest.TestCase):
    def setUp(self):
        book,sample=fixture();self.plan=plan(book,sample)
    def test_only_two_seconds_are_accepted_and_signature_is_bound(self):
        value=build(self.plan);self.assertTrue(validate(self.plan,value))
        for patch_value in (0,1,3,2.0,True):
            changed=dict(value,rt=patch_value)
            changed['s']=weread_sign(sorted_query({k:v for k,v in changed.items() if k!='s'}))
            with self.assertRaises(Exception):validate(self.plan,changed)
        for field,changed_value in (('sm','different'),('co',value['co']+1),('s','bad'),('sg','bad')):
            changed=dict(value,**{field:changed_value})
            with self.assertRaises(Exception):validate(self.plan,changed)
    def test_expired_request_is_rejected(self):
        value=build(self.plan)
        with self.assertRaises(Exception):validate(self.plan,value,now=value['ct']+31)
    def test_unrelated_fixture_and_bad_source_are_rejected(self):
        value=build(self.plan);other=copy.deepcopy(self.plan);other['book']='CB_Other'
        with self.assertRaises(Exception):validate(other,value)
        with patch('cb_fixture_web_time.position_body',return_value={'rt':2}):
            with self.assertRaises(Exception):build(self.plan)


if __name__=='__main__':unittest.main()
