"""A renewed grant can only inspect the same sealed scope on the same device."""
from copy import deepcopy
import unittest

from cloud_group_binding import Binding
from cloud_group_contract import digest
from cloud_group_journal import Journal
from secure_weread_session import StoreError
from test_cloud_group_journal import Memory
from test_secure_native_session import credentials


class BindingTest(unittest.TestCase):
    def setUp(self):
        self.grant=credentials();self.journal=Journal(backend=Memory());self.binding=Binding(backend=Memory())
        native={'groups':{},'members':[],'flags':'n','albums':{'present':True,'value':[]}}
        web={'groups':{},'members':[],'flags':'w','albums':{'present':False}}
        token=self.journal.begin(self.grant['vid'],digest(self.grant),'KOReader-Test-'+'a'*24,digest(native),digest(web))
        token=self.journal.advance(token,'create_claimed');self.journal.close_unchanged(token,[(native,web),(native,web)])
        self.state,self.token=self.journal.read()

    def test_same_device_renewal_matches_only_the_exact_sealed_scope(self):
        self.assertTrue(self.binding.bind(self.state,self.token,self.grant))
        renewed=deepcopy(self.grant);renewed['accessToken']='synthetic-new-access';renewed['refreshToken']='synthetic-new-refresh'
        self.assertTrue(self.binding.matches(self.state,self.token,renewed))
        changed=deepcopy(renewed);changed['deviceId']='eink334691225'+'2'*19
        self.assertFalse(self.binding.matches(self.state,self.token,changed))
        changed=deepcopy(renewed);changed['vid']='900001';self.assertFalse(self.binding.matches(self.state,self.token,changed))
        self.assertFalse(self.binding.matches(self.state,self.token+b' ',renewed))
        with self.assertRaises(StoreError):self.binding.bind(self.state,self.token,self.grant)

    def test_binding_requires_original_grant_and_a_closed_scope(self):
        renewed=deepcopy(self.grant);renewed['accessToken']='synthetic-new-access'
        with self.assertRaises(StoreError):self.binding.bind(self.state,self.token,renewed)
        changed=deepcopy(self.state);changed['phase']='create_claimed'
        with self.assertRaises(StoreError):self.binding.bind(changed,self.token,self.grant)
        self.assertIsNone(self.binding.read())


if __name__=='__main__':unittest.main()
