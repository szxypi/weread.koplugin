"""Strict preflight, exact selection and durable claim precede any permission."""
from copy import deepcopy
import unittest
from unittest.mock import Mock

from native_time_bundle_selection import expected
from native_time_bundle_supervisor import Supervisor
from secure_highlight_trial import Receipt
from secure_weread_session import StoreError
from test_native_time_bundle_gate import fixture,gate


def observed(seconds=6):
    return dict(result='CROSS_DAY_READONLY_VERIFIED',seconds=seconds,exact_capture_and_fixture_bound=True,
        fixture_in_captured_baseline=True,both_positions_source_counts_and_original_shelf_exact=True,
        two_statistics_reads_stable=True,server_clock_after_boundary=True,account_data_posts=0,authentication_posts=0,
        historical_accounting_verified=False,dispatch_capability=False)


def fixture_guard():
    capture,grant,body,now=fixture();gatekeeper=gate(now);store=Mock();receipt=Receipt(b'synthetic-capture')
    store.read.return_value=(capture,receipt);current=Mock(return_value=True);preflight=Mock(return_value=observed())
    task=Supervisor(gatekeeper,store,capture,grant,'synthetic-guest','synthetic-config',current,preflight)
    return task,gatekeeper,store,current,preflight,capture,grant,body


class SupervisorTests(unittest.TestCase):
    def test_full_order_has_no_network_and_ack_is_not_verified_accounting(self):
        task,gatekeeper,_store,_current,preflight,capture,_grant,body=fixture_guard()
        task.prepare();self.assertEqual(gatekeeper.read(),(None,None));preflight.assert_called_once()
        task.select(expected(capture));self.assertEqual(gatekeeper.read(),(None,None))
        task.claim(body,expected(capture));self.assertEqual(gatekeeper.read()[0]['phase'],'claimed')
        task.acknowledge({'succ':1});self.assertEqual(gatekeeper.read()[0]['phase'],'acknowledged')
        for name in ('send','post','request','verify','settle'):self.assertFalse(hasattr(task,name))
        with self.assertRaises(ValueError):task.claim(body,expected(capture))

    def test_incomplete_or_wrong_preflight_does_not_reserve(self):
        flags=('exact_capture_and_fixture_bound','fixture_in_captured_baseline',
               'both_positions_source_counts_and_original_shelf_exact','two_statistics_reads_stable','server_clock_after_boundary')
        for field in (*flags,'result','seconds','account_data_posts','authentication_posts','historical_accounting_verified','dispatch_capability'):
            task,gatekeeper,_store,_current,preflight,_capture,_grant,_body=fixture_guard()
            value=observed();value[field]=None;preflight.return_value=value
            with self.subTest(field=field),self.assertRaises(ValueError):task.prepare()
            self.assertEqual(gatekeeper.read(),(None,None))

    def test_wrong_selection_or_replaced_capture_cannot_claim(self):
        for mode in ('selection','capture','current','grant','token'):
            task,gatekeeper,store,current,_preflight,capture,_grant,body=fixture_guard();task.prepare()
            selection=expected(capture)
            if mode=='selection':selection['parts'][0]['start_time']+=1
            if mode=='capture':store.read.return_value=(capture,Receipt(b'foreign'))
            if mode=='current':current.return_value=False
            if mode=='grant':task.grant['accessToken']='different'
            if mode=='token':task.config_token='different'
            with self.subTest(mode=mode),self.assertRaises(ValueError):task.select(selection)
            self.assertEqual(gatekeeper.read(),(None,None))


    def test_selection_changed_after_confirmation_is_rejected_before_reservation(self):
        task,gatekeeper,_store,_current,_preflight,capture,_grant,body=fixture_guard()
        selection=expected(capture);task.prepare();task.select(selection)
        selection['parts'][0]['start_time']+=1
        with self.assertRaises(ValueError):task.claim(body,selection)
        self.assertEqual(gatekeeper.read(),(None,None))


    def test_state_changes_around_claim_never_release_permission(self):
        for count,expected_phase in ((2,None),(3,'prepared'),(4,'claimed')):
            task,gatekeeper,_store,current,_preflight,capture,_grant,body=fixture_guard()
            selection=expected(capture);task.prepare();task.select(selection)
            current.side_effect=[True]*(count-1)+[False]
            with self.subTest(count=count),self.assertRaises(ValueError):task.claim(body,selection)
            state,_=gatekeeper.read()
            self.assertEqual(state['phase'] if state else None,expected_phase)


    def test_expiry_after_claim_refuses_release_and_keeps_claim(self):
        task,gatekeeper,_store,_current,_preflight,capture,_grant,body=fixture_guard()
        selection=expected(capture);task.prepare();task.select(selection)
        now=body['books'][0]['timestamp'];ticks=iter((now,now,now,now+30));gatekeeper.clock=lambda:next(ticks)
        with self.assertRaisesRegex(ValueError,'bundle_gate/clock'):task.claim(body,selection)
        self.assertEqual(gatekeeper.read()[0]['phase'],'claimed')

    def test_invalid_body_preserves_prepared_scope_and_cannot_retry(self):
        task,gatekeeper,_store,_current,_preflight,capture,_grant,body=fixture_guard();task.prepare();task.select(expected(capture))
        bad=deepcopy(body);bad['books'][0]['readingTime']+=1
        with self.assertRaises(ValueError):task.claim(bad,expected(capture))
        self.assertEqual(gatekeeper.read()[0]['phase'],'prepared')
        with self.assertRaises(StoreError):task.claim(body,expected(capture))
        self.assertEqual(gatekeeper.read()[0]['phase'],'prepared')

    def test_reopen_cannot_reclaim_even_if_previous_reply_was_lost(self):
        task,gatekeeper,store,current,preflight,capture,grant,body=fixture_guard();task.prepare();task.select(expected(capture));task.claim(body,expected(capture))
        reopened=Supervisor(gatekeeper,store,capture,grant,'synthetic-guest','synthetic-config',current,preflight)
        with self.assertRaises(ValueError):reopened.prepare()
        self.assertEqual(gatekeeper.read()[0]['phase'],'claimed')


if __name__=='__main__':unittest.main()
