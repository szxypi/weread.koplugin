"""Read-only signing inputs require a fresh, exact cross-day preflight."""
from copy import deepcopy
import unittest
from unittest.mock import Mock

from native_time_bundle_preparation import SigningInputs,SigningRead,read_signing_inputs
from secure_highlight_trial import Receipt
from test_eink_login import Opener
from test_native_time_bundle_gate import fixture
from test_native_time_bundle_supervisor import observed


def setup():
    bundle,grant,_body,now=fixture();receipt=Receipt(b'synthetic-capture')
    store=Mock();store.backend=object();store.read.return_value=(bundle,receipt)
    gate=Mock();gate.read.return_value=(None,None);current=Mock(return_value=True)
    preflight=observed();preflight['completed_at']=now-2
    probe=Mock();probe.read.return_value=SigningInputs('synthetic-guest','synthetic-config')
    args=dict(bundle=bundle,receipt=receipt,grant=grant,store=store,gate=gate,current=current,
              preflight=preflight,probe=probe,clock=lambda:now)
    return args,probe,store,gate,current


class PreparationTests(unittest.TestCase):
    def test_fresh_inputs_are_private_and_no_journal_or_account_write_occurs(self):
        args,probe,_store,gate,_current=setup();value=read_signing_inputs(**args)
        self.assertEqual(value,SigningInputs('synthetic-guest','synthetic-config'))
        self.assertNotIn('synthetic-guest',repr(value));self.assertNotIn('synthetic-config',repr(value))
        probe.read.assert_called_once();gate.reserve.assert_not_called();gate.claim.assert_not_called()

    def test_stale_boundary_or_incomplete_preflight_stops_before_network(self):
        changes=('early','age','future','owner','capture','gate','session','missing_flag','wrong_seconds','posts')
        for change in changes:
            args,probe,store,gate,current=setup();now=args['clock']()
            if change=='early':args['clock']=lambda:args['bundle']['plan']['not_before']-1
            elif change=='age':args['preflight']['completed_at']=now-30
            elif change=='future':args['preflight']['completed_at']=now+1
            elif change=='owner':args['grant']=dict(args['grant'],vid='900001')
            elif change=='capture':store.read.return_value=(args['bundle'],Receipt(b'other'))
            elif change=='gate':gate.read.return_value=({'phase':'claimed'},Receipt(b'other'))
            elif change=='session':current.return_value=False
            elif change=='missing_flag':args['preflight']['fixture_in_captured_baseline']=False
            elif change=='wrong_seconds':args['preflight']['seconds']=True
            else:args['preflight']['account_data_posts']=1
            with self.subTest(change=change),self.assertRaises(ValueError):read_signing_inputs(**args)
            probe.read.assert_not_called();gate.reserve.assert_not_called()

    def test_changed_session_or_expired_preflight_after_read_stops(self):
        for change in ('session','capture','gate','age'):
            args,probe,store,gate,current=setup();now=args['clock']()
            def read():
                if change=='session':current.return_value=False
                elif change=='capture':store.read.return_value=(args['bundle'],Receipt(b'other'))
                elif change=='gate':gate.read.return_value=({'phase':'claimed'},Receipt(b'other'))
                return SigningInputs('synthetic-guest','synthetic-config')
            probe.read.side_effect=read
            if change=='age':
                ticks=iter((now,now+30));args['clock']=lambda:next(ticks)
            with self.subTest(change=change),self.assertRaises(ValueError):read_signing_inputs(**args)
            gate.reserve.assert_not_called()

    def test_scoped_transport_permits_two_gets_once_and_hides_tokens(self):
        _bundle,grant,_body,_now=fixture();opener=Opener([{'token':'synthetic-config'},{'feature':{'guest_token':'synthetic-guest'}}])
        transport=SigningRead(grant,lambda:True,opener);inputs=transport.read()
        self.assertEqual(inputs,SigningInputs('synthetic-guest','synthetic-config'))
        self.assertEqual(len(opener.requests),2);self.assertTrue(all(req.data is None for req in opener.requests))
        self.assertNotIn('synthetic-config',repr(transport.report));self.assertNotIn('synthetic-guest',repr(transport.report))
        with self.assertRaises(ValueError):transport.read()
        with self.assertRaises(ValueError):transport.request('other','https://i.weread.qq.com/book/batchUploadProgress',body={},credentials=grant)
        self.assertEqual(len(opener.requests),2)


    def test_timeout_is_not_retried(self):
        _bundle,grant,_body,_now=fixture();opener=Opener([TimeoutError()])
        transport=SigningRead(grant,lambda:True,opener)
        with self.assertRaises(Exception):transport.read()
        with self.assertRaises(ValueError):transport.read()
        self.assertEqual(len(opener.requests),1)

    def test_invalid_config_or_changed_owner_never_reads_feature(self):
        _bundle,grant,_body,_now=fixture()
        for config in ({},{'token':''},{'token':False}):
            opener=Opener([config]);transport=SigningRead(grant,lambda:True,opener)
            with self.subTest(config=config),self.assertRaises(ValueError):transport.read()
            self.assertEqual(len(opener.requests),1)
        opener=Opener([{'token':'synthetic-config'}]);current=Mock(side_effect=[True,False])
        with self.assertRaises(ValueError):SigningRead(grant,current,opener).read()
        self.assertEqual(len(opener.requests),1)


if __name__=='__main__':unittest.main()
