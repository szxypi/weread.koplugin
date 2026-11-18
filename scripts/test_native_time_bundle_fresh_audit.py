"""Fresh trial binding survives restart without authorizing a send."""
from copy import deepcopy
import unittest
from unittest.mock import patch

from annotation_experiment_model import canonical
from native_time_bundle_fresh_audit import FreshAuditStore
from secure_weread_session import StoreError
from test_native_time_bundle_accounting import example
from test_native_time_bundle_evidence import fresh_fixture,synthetic_scope
from test_native_time_bundle_fresh_shelf import example as shelf_example
from test_native_time_bundle_gate import fixture,gate
from test_secure_native_session import Backend


def setup():
    _bundle,_grant,_before,_report,now,_pairs,_shelves,_evidence=fresh_fixture()
    bundle,grant,evidence,observations=shelf_example()
    _bundle,_grant,_before,samples,_now=example();_b,_g,body,_n=fixture()
    keeper=gate(now);reservation=keeper.reserve(bundle,grant)
    store=FreshAuditStore(Backend(),clock=lambda:now)
    return bundle,grant,evidence,now,samples,body,keeper,reservation,store,observations


class FreshAuditTests(unittest.TestCase):
    def test_component_baseline_survives_reopen_and_identifies_only_changed_fields(self):
        bundle,grant,evidence,observations=shelf_example(with_components=True)
        now=evidence.for_bundle(bundle,grant)[0]['completed_at'];_b,_g,_before,samples,_n=example()
        _b,_g,body,_n=fixture();keeper=gate(now);reservation=keeper.reserve(bundle,grant)
        store=FreshAuditStore(Backend(),clock=lambda:now);trial=synthetic_scope(bundle)
        store.seal(bundle,grant,keeper,evidence,trial);self.assertEqual(store.read()[0]['schema'],2)
        reopened=FreshAuditStore(store.backend,clock=lambda:now);packet,_,_,_=reopened.inspect(bundle,grant,keeper)
        self.assertIn('components',packet)
        claim=keeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config')
        keeper.acknowledge(claim,{'succ':1})
        changed=deepcopy(observations)
        for row in changed:row['native']['archive'][0]['updateTime']=2
        result=reopened.assess_acknowledged(bundle,grant,keeper,samples,trial,changed)
        self.assertFalse(result['full_shelf_exact']);self.assertTrue(result['component_diagnosis_available'])
        self.assertEqual(result['native_shelf_change']['group_fields_changed'],['updateTime'])
        self.assertEqual(result['web_shelf_change']['group_fields_changed'],[])
        self.assertFalse(result['real_accounting_verified'])
        self.assertNotIn('Synthetic',repr(result));self.assertNotIn('CB_SyntheticOnly',repr(result))

    def test_schema_two_component_corruption_is_rejected(self):
        bundle,grant,evidence,_observations=shelf_example(with_components=True)
        now=evidence.for_bundle(bundle,grant)[0]['completed_at'];keeper=gate(now);keeper.reserve(bundle,grant)
        store=FreshAuditStore(Backend(),clock=lambda:now);store.seal(bundle,grant,keeper,evidence,synthetic_scope(bundle))
        value,_=store.read();next(iter(value['packet']['components'][0]['groups'].values()))['name']='a'*64
        store.backend.save(canonical(value))
        with self.assertRaises(ValueError):store.inspect(bundle,grant,keeper)

    def test_mutated_component_evidence_never_reserves_an_audit(self):
        bundle,grant,evidence,_observations=shelf_example(with_components=True)
        now=evidence.for_bundle(bundle,grant)[0]['completed_at'];keeper=gate(now);keeper.reserve(bundle,grant)
        store=FreshAuditStore(Backend(),clock=lambda:now)
        evidence._components[0]['members']='a'*64
        with self.assertRaises(ValueError):store.seal(bundle,grant,keeper,evidence,synthetic_scope(bundle))
        self.assertEqual(store.read(),(None,None));self.assertEqual(keeper.read()[0]['phase'],'prepared')

    def test_real_keychain_scope_forbids_replacing_clock_or_lock(self):
        import native_time_bundle_fresh_audit as module
        class FakeMac:service=module.SERVICE
        with patch.object(module,'MacKeychain',FakeMac):
            with self.assertRaises(ValueError):FreshAuditStore(FakeMac(),clock=lambda:1)
            with self.assertRaises(ValueError):FreshAuditStore(FakeMac(),lock=lambda:None)

    def test_reopen_same_private_baseline_and_verify_accounting_only_after_ack(self):
        bundle,grant,evidence,now,samples,body,keeper,reservation,store,observations=setup();trial=synthetic_scope(bundle)
        receipt=store.seal(bundle,grant,keeper,evidence,trial)
        reopened=FreshAuditStore(store.backend,clock=lambda:now)
        packet,found,state,_=reopened.inspect(bundle,grant,keeper)
        self.assertEqual((found,state['phase'],packet['trial_scope']),(receipt,'prepared',trial))
        self.assertFalse(packet['report']['previous_native_group_baseline_matches'])
        with self.assertRaisesRegex(ValueError,'no_ack'):reopened.check_acknowledged(bundle,grant,keeper,samples,trial,observations)
        with self.assertRaises(StoreError):store.seal(bundle,grant,keeper,evidence,trial)
        claimed=keeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config')
        keeper.acknowledge(claimed,{'succ':1})
        result=reopened.check_acknowledged(bundle,grant,keeper,samples,trial,observations)
        self.assertEqual(result['result'],'ACCOUNTING_MATCH');self.assertFalse(result['real_accounting_verified'])
        changed=deepcopy(observations)
        for row in changed:row['web']['books'][0]['bookId']='900009'
        partial=reopened.assess_acknowledged(bundle,grant,keeper,samples,trial,changed)
        self.assertFalse(partial['full_shelf_exact']);self.assertFalse(partial['real_accounting_verified'])
        with self.assertRaisesRegex(ValueError,'fresh_shelf/changed'):
            reopened.check_acknowledged(bundle,grant,keeper,samples,trial,changed)
        # A changed shelf never masks a later invalid group or bad accounting.
        changed[1]['group']['web_group_present']=True
        with self.assertRaises(ValueError):reopened.assess_acknowledged(bundle,grant,keeper,samples,trial,changed)
        changed=deepcopy(observations)
        for row in changed:row['web']['books'][0]['bookId']='900009'
        samples[-1]['snapshot']['counts']['ttsTime']+=1
        with self.assertRaises(ValueError):reopened.assess_acknowledged(bundle,grant,keeper,samples,trial,changed)
        observations[1]['web']['books'].pop()
        with self.assertRaises(ValueError):reopened.check_acknowledged(bundle,grant,keeper,samples,trial,observations)
        for name in ('send','post','claim','advance','delete','verify'):self.assertFalse(hasattr(store,name))

    def test_stale_wrong_evidence_or_changed_trial_never_seals(self):
        for mode in ('trial','evidence','bundle','grant','expired','gate'):
            bundle,grant,evidence,now,_samples,body,keeper,reservation,store,_observations=setup();trial=synthetic_scope(bundle)
            if mode=='trial':trial['old_sha256']='a'*64
            elif mode=='evidence':evidence._value=(*evidence._value[:3],('c'*64,'d'*64),evidence._value[4])
            elif mode=='bundle':bundle['plan']['seconds']+=1
            elif mode=='grant':grant['accessToken']='other-synthetic-token'
            elif mode=='expired':store.clock=lambda:now+30
            else:keeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config')
            with self.subTest(mode=mode),self.assertRaises((ValueError,StoreError)):
                store.seal(bundle,grant,keeper,evidence,trial)
            self.assertEqual(store.read(),(None,None))

    def test_corruption_gate_change_or_ambiguous_save_never_overwrites(self):
        bundle,grant,evidence,now,_samples,body,keeper,reservation,store,_observations=setup();trial=synthetic_scope(bundle)
        save=store.backend.save
        def save_then_fail(raw):save(raw);raise StoreError('synthetic_failure')
        with patch.object(store.backend,'save',side_effect=save_then_fail),self.assertRaises(StoreError):
            store.seal(bundle,grant,keeper,evidence,trial)
        with self.assertRaises(StoreError):store.seal(bundle,grant,keeper,evidence,trial)
        value,_=store.read();value['packet']['trial_scope']['owner_sha256']='a'*64
        store.backend.save(canonical(value))
        with self.assertRaises(ValueError):store.inspect(bundle,grant,keeper)

    def test_after_ack_same_device_renewal_is_read_only_and_other_device_fails(self):
        bundle,grant,evidence,_now,samples,body,keeper,reservation,store,observations=setup()
        store.seal(bundle,grant,keeper,evidence,synthetic_scope(bundle))
        claimed=keeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config')
        keeper.acknowledge(claimed,{'succ':1})
        renewed=deepcopy(grant);renewed['accessToken']='renewed-synthetic-token'
        self.assertEqual(store.check_acknowledged(bundle,renewed,keeper,samples,synthetic_scope(bundle),observations)['result'],'ACCOUNTING_MATCH')
        renewed['deviceId']='eink334691225'+'2'*19
        with self.assertRaises(ValueError):store.inspect(bundle,renewed,keeper)


if __name__=='__main__':unittest.main()
