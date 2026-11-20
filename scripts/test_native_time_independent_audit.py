"""Private baseline, single claim and strict read-only accounting tests."""
from copy import deepcopy
import unittest
from unittest.mock import patch

import native_time_independent_audit as task
from cloud_group_contract import project
from native_time_bundle_accounting import day
from native_time_bundle_evidence import IndependentCaptureEvidence
from native_time_independent_gate import IndependentGate
from native_time_shelf_components import make
from readtime_upload_model import batch
from secure_weread_session import ACCOUNT,StoreError
from test_cloud_group_nonempty_contract import source
from test_independent_time_evidence import fixture as evidence_fixture
from test_native_time_independent_gate import Capture
from test_secure_native_session import Backend
from txt_full_summary import digest
from verify_native_statistics import period


def fixture():
    bundle,grant,before,report,now,pairs,_shelves=evidence_fixture()
    native=source();web=deepcopy(native)
    shelves=(digest(project(native)),digest(project(web)))
    components=(make(project(native)),make(project(web)))
    proof=IndependentCaptureEvidence(bundle,grant,report,before['snapshot'],before['months'],pairs,shelves,components=components)
    plan=bundle['plan']
    rows=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')} for row in plan['rows']]
    body=batch(grant,plan['book_id'],rows,'synthetic-guest','synthetic-config',now,123,now*1000,456,current_zone='+08:00')
    after=deepcopy(before['snapshot']);after['counts']['readingTime']+=plan['seconds']
    after_months=deepcopy(before['months']);month=str(period('monthly',plan['start_time'])[0]);bucket=str(day(plan['start_time']))
    after_months[month]['readTimes'][bucket]+=plan['seconds'];after_months[month]['totalReadTime']+=plan['seconds']
    samples=[{'snapshot':deepcopy(after),'months':deepcopy(after_months),'server_at':now+i} for i in range(3)]
    gate=IndependentGate(Backend(),capture=Capture(bundle),clock=lambda:now,zone=lambda:'+08:00')
    journal=task.IndependentAudit(Backend(),clock=lambda:now)
    observations=[{'native':deepcopy(native),'web':deepcopy(web)} for _ in range(2)]
    return bundle,grant,body,now,before,proof,gate,journal,samples,observations


class IndependentAuditTests(unittest.TestCase):
    def acknowledge(self,f):
        bundle,grant,body,_now,_before,proof,gate,journal,_samples,_observations=f
        prepared=gate.reserve(bundle,grant);sealed=journal.seal(bundle,grant,gate,proof)
        claimed=gate.claim(prepared,bundle,grant,body,'synthetic-guest','synthetic-config')
        gate.acknowledge(claimed,{'succ':1})
        return sealed

    def test_seal_claim_ack_and_three_stable_readbacks(self):
        f=fixture();bundle,grant,_body,_now,before,proof,gate,journal,samples,observations=f
        self.assertEqual(journal.read(),(None,None));self.acknowledge(f)
        packet,_,state,_=journal.inspect(bundle,grant,gate)
        self.assertEqual(packet['baseline'],before);self.assertEqual(state['phase'],'acknowledged')
        result=journal.assess_acknowledged(bundle,grant,gate,samples,observations)
        self.assertEqual(result['result'],'ACCOUNTING_MATCH');self.assertTrue(result['full_shelf_exact'])
        self.assertEqual(journal.check_acknowledged(bundle,grant,gate,samples,observations),result)
        self.assertFalse(result['real_accounting_verified']);self.assertEqual(result['independent_samples'],3)
        self.assertEqual(result['seconds'],6);self.assertFalse(hasattr(journal,'send'))
        with self.assertRaises(ValueError):journal.seal(bundle,grant,gate,proof)

    def test_changed_shelf_is_partial_but_unstable_shelf_is_rejected(self):
        f=fixture();bundle,grant,_body,_now,_before,_proof,gate,journal,samples,observations=f
        self.acknowledge(f)
        for item in observations:item['native']['archive'][0]['name']='Changed synthetic group'
        result=journal.assess_acknowledged(bundle,grant,gate,samples,observations)
        self.assertEqual(result['result'],'ACCOUNTING_PARTIAL');self.assertFalse(result['full_shelf_exact'])
        with self.assertRaisesRegex(ValueError,'independent_audit/partial'):
            journal.check_acknowledged(bundle,grant,gate,samples,observations)
        self.assertTrue(result['component_diagnosis_available'])
        self.assertEqual(result['native_shelf_change']['group_fields_changed'],['name'])
        observations[1]['native']['archive'][0]['name']='Changed again'
        with self.assertRaisesRegex(ValueError,'independent_audit/unstable'):
            journal.assess_acknowledged(bundle,grant,gate,samples,observations)

    def test_forged_missing_or_stale_data_never_seals_or_passes(self):
        for change in ('wrong_capture','wrong_grant','bad_samples','unacknowledged','changed_record'):
            f=fixture();bundle,grant,body,_now,_before,proof,gate,journal,samples,observations=f
            prepared=gate.reserve(bundle,grant);journal.seal(bundle,grant,gate,proof)
            if change=='wrong_capture':gate.capture.bundle['plan']['seconds']+=1
            elif change=='wrong_grant':grant['accessToken']='different-synthetic'
            elif change=='changed_record':journal.backend.save(b'{}')
            else:
                claimed=gate.claim(prepared,bundle,grant,body,'synthetic-guest','synthetic-config')
                if change!='unacknowledged':gate.acknowledge(claimed,{'succ':1});samples[0]['months']={}
            with self.subTest(change=change),self.assertRaises((ValueError,StoreError)):
                journal.assess_acknowledged(bundle,grant,gate,samples,observations)

    def test_size_and_time_checked_before_sealing(self):
        f=fixture();bundle,grant,_body,now,_before,proof,gate,journal,_samples,_observations=f
        gate.reserve(bundle,grant);journal.clock=lambda:now+30
        with self.assertRaisesRegex(ValueError,'independent_audit/stale'):journal.seal(bundle,grant,gate,proof)
        self.assertEqual(journal.read(),(None,None));journal.clock=lambda:now
        with patch.object(task,'MAX_RECORD_BYTES',30):
            with self.assertRaises(StoreError):journal.seal(bundle,grant,gate,proof)
        self.assertEqual(journal.read(),(None,None))

    def test_actual_keychain_scope_rejects_override(self):
        class FakeMac(Backend):
            def __init__(self,service=task.SERVICE,account=ACCOUNT):self.service=service;self.account=account;super().__init__()
        with patch.object(task,'MacKeychain',FakeMac):
            with self.assertRaises(ValueError):task.IndependentAudit(FakeMac('org.codex.weread.other'))
            with self.assertRaises(ValueError):task.IndependentAudit(FakeMac(),clock=lambda:1)
            journal=task.IndependentAudit(FakeMac());journal.clock=lambda:1
            with self.assertRaises(ValueError):journal.read()


if __name__=='__main__':unittest.main()
