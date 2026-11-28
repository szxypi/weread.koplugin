"""A private baseline must survive before a claim can be released."""
from copy import deepcopy
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_audit_store import AuditStore
from native_time_bundle_selection import expected
from native_time_bundle_supervisor import AuditedSupervisor
from secure_highlight_trial import Receipt
from secure_weread_session import StoreError
from test_native_time_bundle_accounting import example
from test_native_time_bundle_gate import fixture,gate
from test_native_time_bundle_supervisor import observed
from test_secure_native_session import Backend


def setup():
    bundle,grant,before,_samples,now=example();_bundle,_grant,body,_now=fixture()
    gatekeeper=gate(now);capture=Mock();capture.read.return_value=(bundle,Receipt(b'synthetic-capture'))
    audit=AuditStore(Backend(),clock=lambda:now)
    task=AuditedSupervisor(gatekeeper,capture,bundle,grant,'synthetic-guest','synthetic-config',
                           lambda:True,lambda:observed(completed_at=now),audit_store=audit,
                           snapshot=before['snapshot'],months=before['months'])
    task.prepare();selection=expected(bundle);task.select(selection)
    return task,gatekeeper,audit,bundle,body,selection


class AuditedSupervisorTests(unittest.TestCase):
    def test_baseline_is_sealed_before_claim_and_retained_after_ack(self):
        task,gatekeeper,audit,_bundle,body,selection=setup();claim=gatekeeper.claim
        def check_before(*args,**kwargs):
            self.assertEqual(audit.read()[0]['phase'],'baseline')
            self.assertEqual(gatekeeper.read()[0]['phase'],'prepared')
            return claim(*args,**kwargs)
        with patch.object(gatekeeper,'claim',side_effect=check_before):task.claim(body,selection)
        self.assertEqual(gatekeeper.read()[0]['phase'],'claimed')
        task.acknowledge({'succ':1})
        self.assertEqual(gatekeeper.read()[0]['phase'],'acknowledged')
        self.assertEqual(audit.read()[0]['phase'],'baseline')

    def test_save_failures_never_release_a_claim(self):
        for mode in ('before_save','after_save','wrong_snapshot','wrong_months'):
            task,gatekeeper,audit,_bundle,body,selection=setup();save=audit.backend.save
            if mode=='after_save':
                def fail(raw):save(raw);raise StoreError('synthetic_failure')
            else:
                def fail(_raw):raise StoreError('synthetic_failure')
            if mode=='wrong_snapshot':task.snapshot['point']['chapter_offset']+=1
            if mode=='wrong_months':task.months={}
            with self.subTest(mode=mode):
                if mode in ('before_save','after_save'):
                    with patch.object(audit.backend,'save',side_effect=fail),self.assertRaises(StoreError):task.claim(body,selection)
                else:
                    with self.assertRaises(ValueError):task.claim(body,selection)
                self.assertEqual(gatekeeper.read()[0]['phase'],'prepared')
                self.assertEqual(audit.read()[0]['phase'] if audit.read()[0] else None,'baseline' if mode=='after_save' else None)

    def test_changed_baseline_after_claim_never_releases_permission(self):
        task,gatekeeper,audit,_bundle,body,selection=setup();inspect=audit.inspect
        def change_after(*args):
            saved,receipt,state,gate_receipt=inspect(*args)
            if state['phase']=='claimed':
                saved=deepcopy(saved);saved['snapshot']['counts']['ttsTime']+=1
            return saved,receipt,state,gate_receipt
        with patch.object(audit,'inspect',side_effect=change_after),self.assertRaisesRegex(ValueError,'audit_changed'):
            task.claim(body,selection)
        self.assertEqual(gatekeeper.read()[0]['phase'],'claimed')
        self.assertEqual(audit.read()[0]['phase'],'baseline')
        with self.assertRaises(ValueError):task.claim(body,selection)


if __name__=='__main__':unittest.main()
