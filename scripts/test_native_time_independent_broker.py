"""No stale input or untrusted command reaches an independent worker."""
import unittest
from unittest.mock import Mock,patch

import native_time_independent_broker as task
from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_native_time_independent_audit import fixture


class BrokerTests(unittest.TestCase):
    def setup_case(self):
        bundle,grant,_body,_now,_before,evidence,gate,audit,_samples,_observations=fixture()
        receipt=Receipt(b'synthetic-capture');store=Mock();store.read.return_value=(bundle,receipt)
        prepared=task.Prepared(bundle,receipt,grant,evidence)
        cookies={'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'}
        return prepared,SigningInputs('synthetic-guest','synthetic-config'),cookies,store,gate,audit

    def test_invalid_or_stale_input_never_starts_child(self):
        for mode in ('receipt','account','cookies','command','armed','signing','scope'):
            prepared,signing,cookies,store,gate,audit=self.setup_case();current=Mock(return_value=True);command=['synthetic-worker'];armed=False
            if mode=='receipt':prepared.receipt=Receipt(b'other')
            elif mode=='account':current.return_value=False
            elif mode=='cookies':cookies['wr_vid']='900002'
            elif mode=='command':command=['']
            elif mode=='armed':armed=1
            elif mode=='signing':signing='bad'
            else:gate.capture.bundle['plan']['seconds']+=1
            with self.subTest(mode=mode),patch.object(task.subprocess,'Popen') as spawn,self.assertRaises(Exception):
                task.execute(prepared,signing,cookies,store,gate,audit,current,command,armed=armed)
            spawn.assert_not_called();self.assertEqual(gate.read(),(None,None));self.assertEqual(audit.read(),(None,None))

    def test_worker_start_failure_is_sanitized(self):
        prepared,signing,cookies,store,gate,audit=self.setup_case()
        with patch.object(task.subprocess,'Popen',side_effect=OSError('private synthetic detail')):
            result=task.execute(prepared,signing,cookies,store,gate,audit,lambda:True,['worker'])
        self.assertEqual(result['result'],'UNVERIFIED');self.assertFalse(result['dispatch_may_have_occurred'])
        self.assertNotIn('private',repr(result));self.assertEqual(gate.read(),(None,None));self.assertEqual(audit.read(),(None,None))

    def test_real_scope_rejects_unattested_session_before_spawning(self):
        prepared,signing,cookies,store,gate,audit=self.setup_case()
        gate._real=True;audit._real=True
        with patch.object(task.subprocess,'Popen') as spawn,self.assertRaisesRegex(ValueError,'independent_broker/scope'):
            task.execute(prepared,signing,cookies,store,gate,audit,lambda:True,['worker'])
        spawn.assert_not_called()

    def test_real_scope_never_passes_credentials_to_an_unattested_command(self):
        class FakeMac:
            def __init__(self,service):self.service=service;self.account=task.ACCOUNT
        class FakeBinding:
            def __call__(self):return True
            def matches(self,_grant,_cookies):return True
        for armed in (False,True):
            prepared,signing,cookies,store,gate,audit=self.setup_case()
            gate._real=True;audit._real=True
            store.backend=FakeMac(task.CAPTURE_SERVICE);gate.backend=FakeMac(task.GATE_SERVICE);audit.backend=FakeMac(task.AUDIT_SERVICE)
            with self.subTest(armed=armed),patch.object(task,'MacKeychain',FakeMac),patch.object(task,'AccountBinding',FakeBinding), \
                 patch.object(task,'trusted_command',return_value=['attested']),patch.object(task.subprocess,'Popen') as spawn:
                with self.assertRaisesRegex(ValueError,'independent_broker/command'):
                    task.execute(prepared,signing,cookies,store,gate,audit,FakeBinding(),['untrusted'],armed=armed)
                spawn.assert_not_called()


if __name__=='__main__':unittest.main()
