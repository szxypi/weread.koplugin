"""The ordinary-book broker rejects stale input before starting a worker."""
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_fresh_audit import FreshAuditStore
from native_time_bundle_fresh_broker import Prepared,execute
from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_native_time_bundle_evidence import synthetic_scope
from test_native_time_bundle_fresh_shelf import example
from test_native_time_bundle_gate import gate
from test_secure_native_session import Backend


class BrokerTests(unittest.TestCase):
    def test_invalid_or_stale_input_never_spawns_or_claims(self):
        for mode in ('capture','session','cookies','command','armed','signing','trial'):
            bundle,grant,evidence,_observations=example();now=evidence.for_bundle(bundle,grant)[0]['completed_at']
            receipt=Receipt(b'synthetic');store=Mock();store.read.return_value=(bundle,receipt);keeper=gate(now)
            audit=FreshAuditStore(Backend(),clock=lambda:now);state={'current':True};scope=synthetic_scope(bundle)
            prepared=Prepared(bundle,receipt,grant,evidence);signing=SigningInputs('synthetic-guest','synthetic-config')
            cookies={'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'};command=['synthetic-worker'];armed=False
            if mode=='capture':prepared.receipt=Receipt(b'other')
            elif mode=='session':state['current']=False
            elif mode=='cookies':cookies['wr_vid']='900002'
            elif mode=='command':command=['']
            elif mode=='armed':armed=1
            elif mode=='signing':signing='bad'
            else:scope['old_sha256']='c'*64
            with self.subTest(mode=mode),patch('native_time_bundle_fresh_broker.subprocess.Popen') as spawn,self.assertRaises(ValueError):
                execute(prepared,signing,cookies,store,keeper,audit,lambda:state['current'],lambda:scope,command,armed=armed)
            spawn.assert_not_called();self.assertEqual(keeper.read(),(None,None));self.assertEqual(audit.read(),(None,None))

    def test_process_start_failure_is_sanitized(self):
        bundle,grant,evidence,_observations=example();now=evidence.for_bundle(bundle,grant)[0]['completed_at']
        receipt=Receipt(b'synthetic');store=Mock();store.read.return_value=(bundle,receipt);keeper=gate(now)
        audit=FreshAuditStore(Backend(),clock=lambda:now);prepared=Prepared(bundle,receipt,grant,evidence)
        with patch('native_time_bundle_fresh_broker.subprocess.Popen',side_effect=OSError('synthetic secret')):
            result=execute(prepared,SigningInputs('guest-token','config-token'),{'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'},
                           store,keeper,audit,lambda:True,lambda:synthetic_scope(bundle),['worker'])
        self.assertEqual(result['result'],'UNVERIFIED');self.assertFalse(result['dispatch_may_have_occurred'])
        self.assertNotIn('secret',repr(result));self.assertEqual(keeper.read(),(None,None));self.assertEqual(audit.read(),(None,None))


if __name__=='__main__':unittest.main()
