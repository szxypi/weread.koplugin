"""Fail closed around CB selection, persisted baseline, one claim and ACK."""
from copy import deepcopy
import tempfile,unittest
from unittest.mock import patch

from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_bridge import Bridge
from cb_native_time_bundle_gate import DispatchGate
from cb_native_time_bundle_supervisor import Supervisor
from secure_highlight_trial import Receipt
from secure_weread_session import StoreError
from test_cb_native_time_bundle_accounting import example as accounting_example
from test_cb_native_time_bundle_native_record import setup as record_fixture
from test_secure_native_session import Backend


class Capture:
    def __init__(self,bundle):self.bundle=deepcopy(bundle);self.receipt=Receipt(b'synthetic-capture')
    def read(self):return deepcopy(self.bundle),self.receipt


def fixture(directory,armed=False):
    bundle,grant,evidence,selection,body,record,path,now=record_fixture(directory)
    gate=DispatchGate(Backend(),clock=lambda:now,zone=lambda:'+08:00');audit=AuditStore(Backend(),clock=lambda:now)
    capture=Capture(bundle);state={'current':True}
    supervisor=Supervisor(gate,capture,bundle,grant,'synthetic-guest','synthetic-config',lambda:state['current'],
                          audit_store=audit,evidence=evidence)
    supervisor.prepare();bridge=Bridge(supervisor,path,armed=armed)
    return bundle,grant,evidence,selection,body,record,path,now,gate,audit,capture,state,supervisor,bridge


class ImportedSupervisorTests(unittest.TestCase):
    def test_dry_run_never_reserves_or_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle,grant,evidence,selection,body,record,path,now,gate,audit,_capture,_state,_s,bridge=fixture(directory)
            self.assertTrue(bridge.handle(dict(kind='selection',selection=selection)))
            self.assertFalse(bridge.handle(dict(kind='claim',body=body,selection=selection,record=record)))
            self.assertEqual(gate.read(),(None,None));self.assertEqual(audit.read(),(None,None))
            with self.assertRaises(ValueError):bridge.handle(dict(kind='ack',status=200,response={'succ':1}))
    def test_one_claim_seals_baseline_before_ack_and_readback(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle,grant,evidence,selection,body,record,path,now,gate,audit,_capture,_state,supervisor,bridge=fixture(directory,True)
            self.assertTrue(bridge.handle(dict(kind='selection',selection=selection)))
            self.assertTrue(bridge.handle(dict(kind='claim',body=body,selection=selection,record=record)))
            self.assertEqual(gate.read()[0]['phase'],'claimed');self.assertIsNotNone(audit.read()[0])
            self.assertTrue(bridge.handle(dict(kind='ack',status=200,response={'succ':1})))
            self.assertEqual(gate.read()[0]['phase'],'acknowledged')
            _bundle,_grant,_before,samples,_now=accounting_example()
            result=audit.check_acknowledged(bundle,grant,gate,samples)
            self.assertEqual(result['result'],'ACCOUNTING_MATCH');self.assertFalse(result['real_accounting_verified'])
            with self.assertRaises(ValueError):bridge.handle(dict(kind='claim',body=body,selection=selection,record=record))
            self.assertEqual(supervisor.phase,'acknowledged')
    def test_tampering_stops_before_any_gate_write(self):
        for mode in ('selection','body','point','web','rows','counts','months','shelf','source','catalog','capture','guard','path'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                bundle,grant,evidence,selection,body,record,path,now,gate,audit,capture,state,supervisor,bridge=fixture(directory,True)
                offered=deepcopy(selection)
                if mode=='selection':offered['seconds']+=1
                if mode=='capture':capture.receipt=Receipt(b'changed')
                if mode=='guard':state['current']=False
                try:
                    bridge.handle(dict(kind='selection',selection=offered))
                    if mode=='body':body['books'][0]['summary']='changed'
                    elif mode=='point':record['metadata']['native_hash']='f'*64
                    elif mode=='web':record['metadata']['web_hash']='f'*64
                    elif mode=='rows':record['rows'][0]['duration']+=1
                    elif mode=='counts':record['metadata']['counts']['ttsTime']+=1
                    elif mode=='months':next(iter(record['metadata']['months'].values()))['totalReadTime']+=1
                    elif mode=='shelf':record['metadata']['shelf_hash']='f'*64
                    elif mode=='source':record['metadata']['source']['expected']['raw_sha256']='f'*64
                    elif mode=='catalog':record['metadata']['source']['catalog_stamp']='f'*64
                    elif mode=='path':path.write_bytes(b'changed')
                    bridge.handle(dict(kind='claim',body=body,selection=selection,record=record))
                except (ValueError,StoreError):pass
                else:self.fail('tampered data was accepted')
                self.assertEqual(bridge.phase,'stopped');self.assertEqual(supervisor.phase,'stopped')
                self.assertEqual(gate.read(),(None,None));self.assertEqual(audit.read(),(None,None))
    def test_uncertain_or_failed_audit_never_releases_or_replays(self):
        for mode in ('audit_failure','claim_ambiguous'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                bundle,grant,evidence,selection,body,record,path,now,gate,audit,_capture,_state,supervisor,bridge=fixture(directory,True)
                bridge.handle(dict(kind='selection',selection=selection))
                if mode=='audit_failure':
                    saved=audit.backend.save
                    def save_then_fail(raw):saved(raw);raise StoreError('synthetic audit failure')
                    patched=patch.object(audit.backend,'save',side_effect=save_then_fail)
                else:
                    original=gate.claim
                    def claim_then_fail(*args):original(*args);raise StoreError('synthetic claim failure')
                    patched=patch.object(gate,'claim',side_effect=claim_then_fail)
                with patched,self.assertRaises(StoreError):bridge.handle(dict(kind='claim',body=body,selection=selection,record=record))
                self.assertEqual(gate.read()[0]['phase'],'prepared' if mode=='audit_failure' else 'claimed')
                self.assertIsNotNone(audit.read()[0]);self.assertEqual(bridge.phase,'stopped');self.assertEqual(supervisor.phase,'stopped')
                with self.assertRaises(ValueError):bridge.handle(dict(kind='claim',body=body,selection=selection,record=record))
    def test_receipts_and_order_are_strict(self):
        for status,response in ((201,{'succ':1}),(200,{}),(200,{'succ':'1'}),(True,{'succ':1})):
            with self.subTest(status=status,response=response),tempfile.TemporaryDirectory() as directory:
                _bundle,_grant,_evidence,selection,body,record,_path,_now,gate,_audit,_capture,_state,_supervisor,bridge=fixture(directory,True)
                bridge.handle(dict(kind='selection',selection=selection));bridge.handle(dict(kind='claim',body=body,selection=selection,record=record))
                with self.assertRaises(ValueError):bridge.handle(dict(kind='ack',status=status,response=response))
                self.assertEqual(gate.read()[0]['phase'],'claimed');self.assertEqual(bridge.phase,'stopped')


if __name__=='__main__':unittest.main()
