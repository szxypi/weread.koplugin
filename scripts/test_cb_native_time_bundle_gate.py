"""One real-clock-bound CB time claim; all inputs here are synthetic."""
from copy import deepcopy
import threading,unittest
from unittest.mock import patch

import cb_native_time_bundle_gate as module
from cb_native_readtime_model import batch
from cb_native_time_bundle_gate import DispatchGate,binding,verify_request
from native_time_bundle_gate import SERVICE as PRIOR_SERVICE
from secure_highlight_trial import Receipt
from secure_weread_session import StoreError
from selection_trial_mock import credentials
from test_cb_native_time_capture import fixture
from test_secure_native_session import Backend
from txt_full_summary import digest


def example():
    plan,proof,_,_,_=fixture();grant=credentials();plan['device_sha256']=digest(grant['deviceId'])
    point=dict(chapter_uid=plan['chapter_uid'],chapter_idx=plan['chapter_idx'],chapter_offset=12,raw_percent=25,
               summary=dict(present=True,value='完整合成摘要😀'),chapterTitle=dict(present=True,value='合成章节'))
    snapshot=dict(native=deepcopy(point),web=deepcopy(point),counts=dict(readingTime=3,recordReadingTime=0,ttsTime=0),
                  version=plan['book_version'],native_shelf='a'*64,web_shelf='b'*64,source=plan['raw_sha256'],catalog='c'*64)
    plan['baseline_sha256']=digest(snapshot);capture=dict(plan=plan,evidence=proof);now=plan['not_before']+20
    rows=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')} for row in plan['rows']]
    body=batch(grant,plan['book_id'],rows,'synthetic-guest','synthetic-config',now,123,now*1000,456,
               current_zone='+08:00',summary=point['summary']['value'])
    return capture,grant,snapshot,body,now


class ImportedBundleGateTests(unittest.TestCase):
    def gate(self,now,backend=None,lock=None):
        return DispatchGate(backend or Backend(),lock,clock=lambda:now,zone=lambda:'+08:00')
    def test_boundary_owner_clock_and_separate_scope(self):
        bundle,grant,snapshot,body,now=example();self.assertNotEqual(module.SERVICE,PRIOR_SERVICE)
        early=self.gate(bundle['plan']['not_before']-1)
        with self.assertRaises(ValueError):early.reserve(bundle,grant,snapshot)
        self.assertEqual(early.read(),(None,None))
        for field,value in (('vid','900001'),('deviceId','eink334691225'+'2'*19)):
            changed=dict(grant);changed[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):binding(bundle,changed,snapshot,now)
        self.assertTrue(verify_request(bundle,grant,snapshot,body,'synthetic-guest','synthetic-config',now,'+08:00'))
        with self.assertRaises(ValueError):verify_request(bundle,grant,snapshot,body,'synthetic-guest','synthetic-config',now,'+00:00')
        with self.assertRaises(ValueError):DispatchGate(clock=lambda:now,zone=lambda:'+08:00')
        for name in ('send','request','post','delete','reset'):self.assertFalse(hasattr(early,name))
    def test_real_keychain_never_accepts_injected_clock(self):
        class FakeMac(Backend):pass
        with patch.object(module,'MacKeychain',FakeMac):
            with self.assertRaises(ValueError):DispatchGate(FakeMac(),clock=lambda:1,zone=lambda:'+08:00')
            with self.assertRaises(ValueError):DispatchGate(FakeMac(),lock=lambda:None)
            task=DispatchGate(FakeMac());task.clock=lambda:1
            with self.assertRaises(ValueError):task._wall_clock()
    def test_one_claim_ack_and_private_state(self):
        bundle,grant,snapshot,body,now=example();task=self.gate(now)
        reserved=task.reserve(bundle,grant,snapshot);claimed=task.claim(reserved,bundle,grant,snapshot,body,'synthetic-guest','synthetic-config')
        self.assertTrue(task.assert_claim_current(claimed,bundle,grant,snapshot,body,'synthetic-guest','synthetic-config'))
        record,_=task.read();self.assertEqual(record['phase'],'claimed')
        for secret in ('完整合成摘要','synthetic-guest','synthetic-config',grant['accessToken']):self.assertNotIn(secret,str(record))
        with self.assertRaises(StoreError):task.claim(reserved,bundle,grant,snapshot,body,'synthetic-guest','synthetic-config')
        for bad in ({},{'succ':'1'},{'succ':0},{'succ':True,'errcode':-1}):
            with self.subTest(bad=bad),self.assertRaises(ValueError):task.acknowledge(claimed,bad)
        acknowledged=task.acknowledge(claimed,{'succ':1});self.assertEqual(task.read()[0]['phase'],'acknowledged')
        with self.assertRaises(StoreError):task.acknowledge(acknowledged,{'succ':1})
        with self.assertRaises(StoreError):task.reserve(bundle,grant,snapshot)
    def test_changed_body_or_snapshot_never_claims(self):
        bundle,grant,snapshot,body,now=example()
        for key,value in (('bookId','CB_Other'),('bookVersion',8),('readingTime',7),('summary','changed'),
                          ('currentProgress',1),('signature','0'*64),('random',True)):
            changed=deepcopy(body);changed['books'][0][key]=value;task=self.gate(now);receipt=task.reserve(bundle,grant,snapshot)
            with self.subTest(key=key),self.assertRaises(ValueError):task.claim(receipt,bundle,grant,snapshot,changed,'synthetic-guest','synthetic-config')
            self.assertEqual(task.read()[0]['phase'],'prepared')
        for key in ('native','web','counts','version','native_shelf','web_shelf','source','catalog'):
            changed=deepcopy(snapshot);changed[key]=None
            with self.subTest(key=key),self.assertRaises(ValueError):binding(bundle,grant,changed,now)
        for field in ('summary','chapter_uid','chapter_offset','raw_percent'):
            changed=deepcopy(snapshot);changed['web'][field]=None
            updated=deepcopy(bundle);updated['plan']['baseline_sha256']=digest(changed)
            with self.subTest(field=field),self.assertRaises(ValueError):binding(updated,grant,changed,now)
        for text in ('','bad\0text','文'*513):
            changed=deepcopy(snapshot)
            for side in ('native','web'):changed[side]['summary']['value']=text
            updated=deepcopy(bundle);updated['plan']['baseline_sha256']=digest(changed)
            with self.subTest(summary=text[:5]),self.assertRaises(ValueError):binding(updated,grant,changed,now)
        with self.assertRaises(ValueError):verify_request(bundle,grant,snapshot,body,'synthetic-guest','synthetic-config',now+30,'+08:00')
    def test_native_numeric_and_web_string_chapter_ids_are_canonicalized(self):
        bundle,grant,snapshot,body,now=example()
        snapshot['native']['chapter_uid']=int(bundle['plan']['chapter_uid'])
        bundle['plan']['baseline_sha256']=digest(snapshot)
        self.assertTrue(binding(bundle,grant,snapshot,now))
        self.assertTrue(verify_request(bundle,grant,snapshot,body,'synthetic-guest','synthetic-config',now,'+08:00'))
        for invalid in (True,0,2**53,'02','CB_Chapter'):
            changed=deepcopy(snapshot);changed['native']['chapter_uid']=invalid
            revised=deepcopy(bundle);revised['plan']['baseline_sha256']=digest(changed)
            with self.subTest(uid=invalid),self.assertRaises(ValueError):binding(revised,grant,changed,now)
    def test_competing_claim_and_ambiguous_storage_never_replay(self):
        bundle,grant,snapshot,body,now=example();lock=threading.Lock();task=self.gate(now,lock=lambda:lock)
        receipt=task.reserve(bundle,grant,snapshot);barrier=threading.Barrier(2);results=[]
        def run():
            barrier.wait()
            try:task.claim(receipt,bundle,grant,snapshot,body,'synthetic-guest','synthetic-config');results.append('claimed')
            except StoreError:results.append('denied')
        threads=[threading.Thread(target=run) for _ in range(2)]
        for thread in threads:thread.start()
        for thread in threads:thread.join()
        self.assertCountEqual(results,['claimed','denied'])
        task=self.gate(now);receipt=task.reserve(bundle,grant,snapshot);save=task.backend.save
        def save_then_fail(raw):save(raw);raise StoreError('synthetic readback')
        with patch.object(task.backend,'save',side_effect=save_then_fail),self.assertRaises(StoreError):
            task.claim(receipt,bundle,grant,snapshot,body,'synthetic-guest','synthetic-config')
        self.assertEqual(task.read()[0]['phase'],'claimed')
        with self.assertRaises(StoreError):task.claim(receipt,bundle,grant,snapshot,body,'synthetic-guest','synthetic-config')


if __name__=='__main__':unittest.main()
