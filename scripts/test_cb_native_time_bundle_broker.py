"""CB broker rejects invalid or stale inputs before spawning a worker."""
import tempfile,unittest
from unittest.mock import patch

from cb_native_time_bundle_broker import execute
from cb_native_time_bundle_preflight import Prepared
from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_cb_native_time_bundle_supervisor import fixture


class BrokerBoundaryTests(unittest.TestCase):
    def test_invalid_or_stale_input_never_spawns(self):
        for mode in ('stale_capture','stale_session','cookies','command','armed','signing'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                bundle,grant,evidence,_selection,_body,_record,_path,_now,gate,audit,store,state,_supervisor,_bridge=fixture(directory)
                prepared=Prepared(bundle,store.receipt,grant,evidence);signing=SigningInputs('synthetic-guest','synthetic-config')
                cookies={'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'};command=['synthetic-worker'];armed=False
                if mode=='stale_capture':prepared.receipt=Receipt(b'other')
                elif mode=='stale_session':state['current']=False
                elif mode=='cookies':cookies['wr_vid']='900001'
                elif mode=='command':command=['']
                elif mode=='armed':armed=1
                else:signing='not signing inputs'
                with patch('cb_native_time_bundle_broker.subprocess.Popen') as spawn,self.assertRaises(ValueError):
                    execute(prepared,signing,cookies,store,gate,audit,lambda:state['current'],command,armed=armed)
                spawn.assert_not_called();self.assertEqual(gate.read(),(None,None));self.assertEqual(audit.read(),(None,None))

    def test_process_start_failure_is_sanitized_and_no_claim_occurs(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle,grant,evidence,_selection,_body,_record,_path,_now,gate,audit,store,_state,_supervisor,_bridge=fixture(directory)
            prepared=Prepared(bundle,store.receipt,grant,evidence)
            with patch('cb_native_time_bundle_broker.subprocess.Popen',side_effect=OSError('synthetic secret')):
                result=execute(prepared,SigningInputs('guest-token','config-token'),
                               {'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'},store,gate,audit,lambda:True,['worker'])
            self.assertEqual(result['result'],'UNVERIFIED');self.assertFalse(result['dispatch_may_have_occurred'])
            self.assertNotIn('secret',repr(result));self.assertEqual(gate.read(),(None,None));self.assertEqual(audit.read(),(None,None))


if __name__=='__main__':unittest.main()
