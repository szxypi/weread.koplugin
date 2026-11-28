"""Signing inputs require fresh CB evidence; no write or renewal path."""
from copy import deepcopy
import unittest
from unittest.mock import Mock,patch

from cb_native_time_bundle_preflight import Prepared
from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_cb_native_time_bundle_evidence import fixture
from cb_native_time_bundle_evidence import PreflightEvidence
import cb_native_time_bundle_preparation as task


class PreparationTests(unittest.TestCase):
    def setup_case(self):
        bundle,grant,report,snapshot,months,pairs=fixture();evidence=PreflightEvidence(bundle,grant,report,snapshot,months,pairs)
        receipt=Receipt(b'synthetic');prepared=Prepared(deepcopy(bundle),receipt,deepcopy(grant),evidence)
        store=Mock();store.backend=None;store.read.return_value=(deepcopy(bundle),receipt)
        gate=Mock();gate.backend=None;gate.read.return_value=(None,None)
        audit=Mock();audit.backend=None;audit.read.return_value=(None,None)
        state={'current':True,'reads':0}
        class Probe:
            def __init__(self,provided,current):self.grant=deepcopy(provided);self.current=current
            def read(self):
                assert self.current();state['reads']+=1
                return SigningInputs('synthetic-guest','synthetic-config')
        return prepared,store,gate,audit,state,Probe,report['completed_at']
    def test_only_two_scoped_read_inputs_and_no_journal_changes(self):
        prepared,store,gate,audit,state,probe,now=self.setup_case()
        value=task.read_inputs(prepared,store,gate,audit,lambda:state['current'],clock=lambda:now,probe_factory=probe)
        self.assertEqual((value.guest,value.config_token),('synthetic-guest','synthetic-config'));self.assertEqual(state['reads'],1)
        self.assertEqual(gate.read(),(None,None));self.assertEqual(audit.read(),(None,None))
    def test_stale_or_changed_scope_never_prepares(self):
        for mode in ('time','capture','gate','audit','session','grant'):
            with self.subTest(mode=mode):
                prepared,store,gate,audit,state,probe,now=self.setup_case()
                if mode=='time':now+=30
                elif mode=='capture':store.read.return_value=(None,None)
                elif mode=='gate':gate.read.return_value=({'phase':'claimed'},Receipt(b'claimed'))
                elif mode=='audit':audit.read.return_value=({'phase':'baseline'},Receipt(b'audit'))
                elif mode=='session':state['current']=False
                else:prepared.grant['accessToken']='different-token'
                with self.assertRaises(ValueError):task.read_inputs(prepared,store,gate,audit,lambda:state['current'],clock=lambda:now,probe_factory=probe)
                self.assertEqual(state['reads'],0)
    def test_midread_session_change_stops_without_reserving(self):
        prepared,store,gate,audit,state,_probe,now=self.setup_case()
        class Changed:
            def __init__(self,grant,_current):self.grant=deepcopy(grant)
            def read(self):state['current']=False;return SigningInputs('synthetic-guest','synthetic-config')
        with self.assertRaises(ValueError):task.read_inputs(prepared,store,gate,audit,lambda:state['current'],clock=lambda:now,probe_factory=Changed)
        self.assertEqual(gate.read(),(None,None));self.assertEqual(audit.read(),(None,None))
    def test_real_scope_rejects_injected_probe_or_clock(self):
        prepared,store,gate,audit,state,probe,now=self.setup_case()
        class FakeMac:pass
        store.backend=FakeMac()
        with patch.object(task,'MacKeychain',FakeMac),self.assertRaises(ValueError):
            task.read_inputs(prepared,store,gate,audit,lambda:True,clock=lambda:now,probe_factory=probe)


if __name__=='__main__':unittest.main()
