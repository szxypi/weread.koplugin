"""A single evidenced native window can be claimed once, never replayed."""
from copy import deepcopy
import threading
import multiprocessing
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import native_time_bundle_gate as gate_module
from native_time_bundle_gate import DispatchGate, binding, verify_request
from readtime_upload_model import batch
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import StoreError
from selection_trial_mock import credentials
from test_native_time_capture_evidence import bundle, make_fixture
from test_secure_native_session import Backend
from txt_full_summary import digest as captured_digest


def fixture():
    plan,ledger,coverage=make_fixture();grant=credentials();plan['device_sha256']=captured_digest(grant['deviceId'])
    proof=bundle(ledger,coverage);ledger.close();coverage.close()
    capture={'plan':plan,'evidence':proof};now=plan['not_before']+20
    rows=[{k:r[k] for k in ('start_time','duration','time_zone','book_version')} for r in plan['rows']]
    body=batch(grant,plan['book_id'],rows,'synthetic-guest','synthetic-config',now,123,now*1000,456,current_zone='+08:00')
    return capture,grant,body,now


def gate(now,backend=None,lock=None):
    return DispatchGate(backend or Backend(),lock,clock=lambda:now,zone=lambda:'+08:00')


class FileBackend:
    def __init__(self,path):self.path=Path(path)
    def load(self):return self.path.read_bytes() if self.path.exists() else None
    def save(self,data):
        temporary=self.path.with_name(self.path.name+'.'+str(os.getpid()))
        temporary.write_bytes(data);os.replace(temporary,self.path)


def competing_worker(path,lock_path,bundle,grant,body,now,receipt,start,results):
    task=DispatchGate(FileBackend(path),lambda:project_lock(Path(lock_path)),clock=lambda:now,zone=lambda:'+08:00')
    start.wait()
    try:task.claim(receipt,bundle,grant,body,'synthetic-guest','synthetic-config');results.put('claimed')
    except StoreError:results.put('denied')


class BundleGateTests(unittest.TestCase):
    def test_no_network_methods_or_implicit_journal_mutation(self):
        bundle,grant,body,now=fixture();task=gate(now)
        self.assertEqual(task.read(),(None,None))
        self.assertIsInstance(verify_request(bundle,grant,body,'synthetic-guest','synthetic-config',now,'+08:00'),str)
        self.assertEqual(task.read(),(None,None))
        for method in ('send','request','post','delete','reset','verify'):self.assertFalse(hasattr(task,method))
        with self.assertRaisesRegex(ValueError,'bundle_gate/clock_override'):
            DispatchGate(clock=lambda:now,zone=lambda:'+08:00')

    def test_requires_natural_historical_boundary_owner_device_and_timezone(self):
        bundle,grant,_body,now=fixture();task=gate(now-21)
        with self.assertRaises(ValueError):task.reserve(bundle,grant)
        self.assertEqual(task.read(),(None,None))
        for field,value in (('vid','900001'),('deviceId','eink334691225'+'2'*19)):
            changed=dict(grant);changed[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):binding(bundle,changed,now)
        task=DispatchGate(Backend(),clock=lambda:now,zone=lambda:'+00:00')
        with self.assertRaises(ValueError):task.reserve(bundle,grant)
        self.assertEqual(task.read(),(None,None))


    def test_real_scope_rejects_replaced_clock_even_after_construction(self):
        bundle,grant,_body,now=fixture()
        class FakeMac(Backend):
            service=gate_module.SERVICE
        with patch.object(gate_module,'MacKeychain',FakeMac):
            task=DispatchGate(FakeMac());task.clock=lambda:now
            with self.assertRaisesRegex(ValueError,'bundle_gate/clock_override'):task.reserve(bundle,grant)
            self.assertEqual(task.read(),(None,None))

    def test_one_claim_then_only_explicit_ack_fact(self):
        bundle,grant,body,now=fixture();task=gate(now)
        reserved=task.reserve(bundle,grant);self.assertEqual(task.read()[0]['phase'],'prepared')
        claimed=task.claim(reserved,bundle,grant,body,'synthetic-guest','synthetic-config')
        record,_=task.read();self.assertEqual(record['phase'],'claimed');self.assertEqual(record['claimed_at'],now)
        self.assertNotIn('synthetic-guest',str(record));self.assertNotIn('synthetic-config',str(record))
        with self.assertRaises(StoreError):task.claim(reserved,bundle,grant,body,'synthetic-guest','synthetic-config')
        with self.assertRaises(StoreError):task.reserve(bundle,grant)
        for value in ({},{'succ':'1'},{'succ':0},{'succ':True,'errcode':-1}):
            with self.subTest(value=value),self.assertRaises(ValueError):task.acknowledge(claimed,value)
        self.assertEqual(task.read()[0]['phase'],'claimed')
        acknowledged=task.acknowledge(claimed,{'succ':1});self.assertEqual(task.read()[0]['phase'],'acknowledged')
        with self.assertRaises(StoreError):task.acknowledge(claimed,{'succ':1})
        with self.assertRaises(StoreError):task.claim(acknowledged,bundle,grant,body,'synthetic-guest','synthetic-config')
        self.assertEqual(task.read()[0]['phase'],'acknowledged')

    def test_body_or_signing_mutations_cannot_consume_claim(self):
        bundle,grant,body,now=fixture()
        edits=[]
        for key,value in (('bookId','900002'),('bookVersion',8),('readingTime',7),('summary','changed'),
                          ('deviceId','different'),('currentProgress',1),('progress',False),('finish',0),('signature','0'*64),('random',True)):
            item=deepcopy(body);item['books'][0][key]=value;edits.append(item)
        extra=deepcopy(body);extra['books'][0]['chapterOffset']=3;edits.append(extra)
        shifted=deepcopy(body);shifted['books'][0]['hours'][0]['startOfHour']+=3600;edits.append(shifted)
        for item in edits:
            task=gate(now);receipt=task.reserve(bundle,grant)
            with self.subTest(item=item),self.assertRaises(ValueError):task.claim(receipt,bundle,grant,item,'synthetic-guest','synthetic-config')
            self.assertEqual(task.read()[0]['phase'],'prepared')
        for guest,config,zone,clock in (('wrong','synthetic-config','+08:00',now),('synthetic-guest','wrong','+08:00',now),
                                        ('synthetic-guest','synthetic-config','+00:00',now),('synthetic-guest','synthetic-config','+08:00',now+30)):
            with self.subTest(zone=zone,clock=clock),self.assertRaises(ValueError):verify_request(bundle,grant,body,guest,config,clock,zone)

    def test_bundle_grant_or_receipt_replacement_stops_before_claim(self):
        bundle,grant,body,now=fixture()
        for mode in ('bundle','grant','receipt'):
            task=gate(now);receipt=task.reserve(bundle,grant);changed=deepcopy(bundle);g=dict(grant)
            if mode=='bundle':changed['evidence']['coverage_sha256']='0'*64
            elif mode=='grant':g['accessToken']='different-token'
            else:receipt=Receipt(b'foreign')
            with self.subTest(mode=mode),self.assertRaises((ValueError,StoreError)):
                task.claim(receipt,changed,g,body,'synthetic-guest','synthetic-config')
            self.assertEqual(task.read()[0]['phase'],'prepared')

    def test_committed_claim_survives_ambiguous_keychain_error(self):
        bundle,grant,body,now=fixture();task=gate(now);receipt=task.reserve(bundle,grant)
        save=task.backend.save
        def saved_then_failed(raw):save(raw);raise StoreError('synthetic_readback_failure')
        with patch.object(task.backend,'save',side_effect=saved_then_failed),self.assertRaises(StoreError):
            task.claim(receipt,bundle,grant,body,'synthetic-guest','synthetic-config')
        self.assertEqual(task.read()[0]['phase'],'claimed')
        with self.assertRaises(StoreError):task.claim(receipt,bundle,grant,body,'synthetic-guest','synthetic-config')


    def test_clock_is_rechecked_immediately_before_durable_claim(self):
        bundle,grant,body,now=fixture();clock=iter((now,now,now+30))
        task=DispatchGate(Backend(),clock=lambda:next(clock),zone=lambda:'+08:00')
        receipt=task.reserve(bundle,grant)
        with self.assertRaisesRegex(ValueError,'bundle_gate/clock'):
            task.claim(receipt,bundle,grant,body,'synthetic-guest','synthetic-config')
        self.assertEqual(task.read()[0]['phase'],'prepared')


    def test_expiry_after_durable_claim_never_releases_permission(self):
        bundle,grant,body,now=fixture();clock=[now]
        task=DispatchGate(Backend(),clock=lambda:clock[0],zone=lambda:'+08:00')
        reserved=task.reserve(bundle,grant);claimed=task.claim(reserved,bundle,grant,body,'synthetic-guest','synthetic-config')
        self.assertTrue(task.assert_claim_current(claimed,bundle,grant,body,'synthetic-guest','synthetic-config'))
        clock[0]+=30
        with self.assertRaisesRegex(ValueError,'bundle_gate/clock'):
            task.assert_claim_current(claimed,bundle,grant,body,'synthetic-guest','synthetic-config')
        self.assertEqual(task.read()[0]['phase'],'claimed')
        with self.assertRaises(StoreError):task.reserve(bundle,grant)

    def test_competing_claims_only_one_wins(self):
        bundle,grant,body,now=fixture();lock=threading.Lock();task=gate(now,lock=lambda:lock);receipt=task.reserve(bundle,grant)
        results=[];start=threading.Barrier(2)
        def worker():
            start.wait()
            try:task.claim(receipt,bundle,grant,body,'synthetic-guest','synthetic-config');results.append('claimed')
            except StoreError:results.append('denied')
        threads=[threading.Thread(target=worker) for _ in range(2)]
        for thread in threads:thread.start()
        for thread in threads:thread.join()
        self.assertCountEqual(results,['claimed','denied']);self.assertEqual(task.read()[0]['phase'],'claimed')


    def test_separate_processes_cannot_claim_the_same_scope(self):
        bundle,grant,body,now=fixture();ctx=multiprocessing.get_context('fork')
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'journal';lock_path=Path(directory)/'journal.lock'
            task=DispatchGate(FileBackend(path),lambda:project_lock(lock_path),clock=lambda:now,zone=lambda:'+08:00')
            receipt=task.reserve(bundle,grant);start=ctx.Barrier(2);results=ctx.Queue()
            workers=[ctx.Process(target=competing_worker,args=(path,lock_path,bundle,grant,body,now,receipt,start,results)) for _ in range(2)]
            for worker in workers:worker.start()
            for worker in workers:worker.join(15);self.assertEqual(worker.exitcode,0)
            self.assertCountEqual([results.get(timeout=2),results.get(timeout=2)],['claimed','denied'])
            self.assertEqual(task.read()[0]['phase'],'claimed')


if __name__=='__main__':unittest.main()
