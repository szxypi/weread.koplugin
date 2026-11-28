"""A consumed request remains inspectable after same-device renewal only."""
from copy import deepcopy
import unittest

from cloud_group_contract import digest
from cloud_group_nonempty_binding import Binding
from cloud_group_nonempty_inspect import _same_scope
from cloud_group_nonempty_journal import Journal
from secure_weread_session import StoreError
from test_cloud_group_nonempty_journal import plan
from test_secure_native_session import Backend,credentials


class BindingTest(unittest.TestCase):
    def setUp(self):
        self.grant=credentials();self.journal=Journal(Backend());values=plan()
        values.update(owner=self.grant['vid'],grant_hash=digest(self.grant))
        token=self.journal.begin(**values);token=self.journal.advance(token,'create_claimed')
        self.token=self.journal.claim_dispatch(token,'create_claimed');self.state,_=self.journal.read()
        self.binding=Binding(Backend())

    def test_bind_once_and_only_exact_owner_device_and_journal(self):
        self.assertTrue(self.binding.bind(self.state,self.token,self.grant))
        renewed=deepcopy(self.grant);renewed['accessToken']='synthetic-new-access';renewed['refreshToken']='synthetic-new-refresh'
        self.assertTrue(self.binding.matches(self.state,self.token,renewed));self.assertTrue(_same_scope(self.state,self.token,renewed,self.binding))
        changed=deepcopy(renewed);changed['deviceId']='eink334691225'+'2'*19
        self.assertFalse(self.binding.matches(self.state,self.token,changed))
        changed=deepcopy(renewed);changed['vid']='900001';self.assertFalse(self.binding.matches(self.state,self.token,changed))
        self.assertFalse(self.binding.matches(self.state,self.token+b' ',renewed))
        with self.assertRaises(StoreError):self.binding.bind(self.state,self.token,self.grant)

    def test_cannot_bind_undispatched_or_new_grant(self):
        changed=deepcopy(self.state);changed['dispatched']=False
        with self.assertRaises(StoreError):self.binding.bind(changed,self.token,self.grant)
        renewed=deepcopy(self.grant);renewed['accessToken']='synthetic-new-access'
        with self.assertRaises(StoreError):self.binding.bind(self.state,self.token,renewed)
        self.assertIsNone(self.binding.read())


if __name__=='__main__':unittest.main()
