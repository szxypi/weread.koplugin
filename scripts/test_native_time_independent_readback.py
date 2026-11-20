"""Readback accepts only bounded observations for the acknowledged capture."""
from copy import deepcopy
import base64
import io
import time
import unittest
from unittest.mock import Mock,patch
import zipfile

from cloud_group_contract import project
from native_time_bundle_evidence import IndependentCaptureEvidence
from native_time_independent_audit import IndependentAudit
from native_time_independent_gate import IndependentGate
from native_time_independent_readback import BoundNative,run
from native_time_shelf_components import make
from readtime_upload_model import batch
from secure_highlight_trial import Receipt
from test_eink_login import Opener
from test_independent_time_evidence import fixture as evidence_fixture
from test_native_time_bundle_evidence import synthetic_catalog,synthetic_pairs
from test_native_time_independent_gate import Capture
from test_secure_native_session import Backend
from test_cloud_group_nonempty_contract import source
from txt_full_summary import digest
from verify_eink_login import BASE
from verify_native_statistics import period
from native_time_bundle_gate import day
from shelf_flag_change_contract import state_hash


def setup_case(ack=True):
    bundle,grant,before,report,now,pairs,_old=evidence_fixture();plan=bundle['plan']
    shelf=source();shelf['books'].append({'bookId':plan['book_id'],'title':'Synthetic book','finishReading':0})
    shelfhash=digest(project(shelf));components=make(project(shelf))
    proof=IndependentCaptureEvidence(bundle,grant,report,before['snapshot'],before['months'],pairs,
                                     (shelfhash,shelfhash),components=(components,components))
    gate=IndependentGate(Backend(),capture=Capture(bundle),clock=lambda:now,zone=lambda:'+08:00')
    audit=IndependentAudit(Backend(),clock=lambda:now)
    reservation=gate.reserve(bundle,grant);audit.seal(bundle,grant,gate,proof)
    if ack:
        rows=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')} for row in plan['rows']]
        body=batch(grant,plan['book_id'],rows,'synthetic-guest','synthetic-config',now,123,now*1000,456,current_zone='+08:00')
        claimed=gate.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config');gate.acknowledge(claimed,{'succ':1})
    store=Mock();store.backend=object();store.read.return_value=(bundle,Receipt(b'synthetic-capture'))
    after=deepcopy(before['snapshot']);after['counts']['readingTime']+=plan['seconds']
    months=deepcopy(before['months']);month=str(period('monthly',plan['start_time'])[0]);bucket=str(day(plan['start_time']))
    months[month]['readTimes'][bucket]+=plan['seconds'];months[month]['totalReadTime']+=plan['seconds']
    return bundle,grant,now,pairs,gate,audit,store,shelf,after,months


class ReadbackTests(unittest.TestCase):
    def test_guarded_native_reads_are_get_only_ordered_and_bounded(self):
        bundle,grant,now,*_=setup_case();plan=bundle['plan'];opener=Opener([{'timestamp':now},{},{}]*3)
        reader=BoundNative(grant,plan,lambda:True,clock=lambda:now,opener=opener)
        for _ in range(3):
            for stage,url in reader.allowed:reader.request(stage,url,credentials=grant)
        self.assertEqual(reader.steps,9);self.assertEqual(len(opener.requests),9)
        self.assertTrue(all(req.data is None and req.get_header('Cookie') is None for req in opener.requests))
        with self.assertRaises(ValueError):reader.request(*reader.allowed[0],credentials=grant)
        for mode in ('stage','url','post','grant','session','timeout'):
            opener=Opener([TimeoutError()] if mode=='timeout' else [{}]);current=lambda:mode!='session'
            reader=BoundNative(grant,plan,current,clock=lambda:now,opener=opener);stage,url=reader.allowed[0];body=None;credential=grant
            if mode=='stage':stage='wrong'
            elif mode=='url':url=BASE+'/book/batchUploadProgress'
            elif mode=='post':body={}
            elif mode=='grant':credential=dict(grant,vid='900002')
            with self.subTest(mode=mode),self.assertRaises(Exception):reader.request(stage,url,body=body,credentials=credential)
            self.assertEqual(len(opener.requests),1 if mode=='timeout' else 0)
            if mode=='timeout':
                with self.assertRaises(ValueError):reader.request(stage,url,credentials=credential)
                self.assertEqual(len(opener.requests),1)

    def test_observations_and_fail_closed_cases(self):
        for mode in ('match','partial','unstable_shelf','changed_accounting','changed_catalog','stale_session','expired','unacknowledged'):
            bundle,grant,now,pairs,gate,audit,store,shelf,after,months=setup_case(ack=mode!='unacknowledged');plan=bundle['plan']
            before_gate=gate.read();before_audit=audit.read();current=Mock(return_value=True)
            web=Mock();web.shards={};web.book_id=plan['book_id'];web.chapter=plan['chapter_uid']
            web._time_catalog_pair=deepcopy(pairs[0]);web.inspect.return_value={'cloud_position_stable':True,'catalog_stable':True}
            changed=deepcopy(shelf);changed['archive'][0]['updateTime']=2
            self.assertEqual(state_hash(changed),state_hash(shelf))
            web.request.return_value=deepcopy(shelf)
            native_open=Opener([{'timestamp':now},{},{}]*3)
            from native_time_bundle_readback import StatisticsReads,ShelfRead
            ordered=sorted(months,key=int);stats_open=Opener([deepcopy(months[key]) for _ in range(3) for key in ordered])
            shelves=[deepcopy(changed if mode=='partial' else shelf)]*2
            if mode=='unstable_shelf':shelves[1]=deepcopy(changed)
            shelf_open=Opener(shelves)
            count=[0]
            def sample(_web,native,credentials):
                for stage,url in native.allowed:native.request(stage,url,credentials=credentials)
                count[0]+=1;value=deepcopy(after)
                if mode=='changed_accounting' and count[0]==3:value['counts']['ttsTime']+=1
                if mode=='changed_catalog' and count[0]==2:
                    web._time_catalog_pair=synthetic_pairs(synthetic_catalog(plan))[0]
                    web._time_catalog_pair[1][0]['updated'][0]['chapterIdx']+=1
                if mode=='stale_session' and count[0]==2:current.return_value=False
                return value
            args=dict(saved={'vid':plan['owner'],'cookies':{'wr_vid':plan['owner'],'wr_skey':'mock_key'}},grant=grant,
                store=store,gate=gate,audit=audit,current=current,clock=lambda:now+(181 if mode=='expired' else 0),sleep=lambda _:None,
                web_factory=lambda _book:web,native_factory=lambda grant,plan,current,clock:BoundNative(grant,plan,current,clock,opener=native_open),
                statistics_factory=lambda grant,months,current:StatisticsReads(grant,months,current,stats_open),
                shelf_factory=lambda grant,current:ShelfRead(grant,current,shelf_open),snapshot=sample)
            with self.subTest(mode=mode):
                if mode in ('match','partial'):
                    result=run(**args);self.assertEqual(result['result'],'READBACK_MATCH' if mode=='match' else 'READBACK_PARTIAL')
                    self.assertEqual(result['independent_samples'],3);self.assertFalse(result['real_accounting_verified'])
                    self.assertEqual(len(native_open.requests),9);self.assertEqual(len(stats_open.requests),3*len(ordered))
                    self.assertEqual(len(shelf_open.requests),2)
                    if mode=='partial':self.assertEqual(result['native_shelf_change']['group_fields_changed'],['updateTime'])
                else:
                    with self.assertRaises(ValueError):run(**args)
                self.assertEqual(gate.read(),before_gate);self.assertEqual(audit.read(),before_audit)
                self.assertTrue(all(req.data is None for req in native_open.requests+stats_open.requests+shelf_open.requests))
                if mode in ('expired','unacknowledged'):self.assertEqual(len(native_open.requests)+len(stats_open.requests)+len(shelf_open.requests),0)

    def test_real_scope_refuses_transport_overrides_before_any_read(self):
        import native_time_independent_readback as module
        class FakeMac:pass
        bundle,grant,_now,_pairs,gate,audit,store,_shelf,_after,_months=setup_case();store.backend=FakeMac()
        with patch.object(module,'MacKeychain',FakeMac):
            with self.assertRaisesRegex(ValueError,'independent_readback/override'):
                run(saved={},grant=grant,store=store,gate=gate,audit=audit,current=lambda:True,clock=lambda:0)
        store.read.assert_not_called()

    def test_actual_snapshot_parser_and_guarded_adapters_match(self):
        bundle,grant,before,report,now,_pairs,_old=evidence_fixture();plan=bundle['plan']
        record=synthetic_catalog(plan);pairs=synthetic_pairs(record)
        shelf=source();shelf['books'].append({'bookId':plan['book_id'],'title':'Synthetic book','finishReading':0})
        before['snapshot']['shelf']=state_hash(shelf)
        before['snapshot']['catalog']=digest({'book_id':plan['book_id'],
            'versions':[plan['book_version'],plan['book_version']],'chapters':record['updated']})
        plan['baseline_sha256']=digest(before['snapshot'])
        projection=project(shelf);proof=IndependentCaptureEvidence(bundle,grant,report,before['snapshot'],before['months'],pairs,
            (digest(projection),digest(projection)),components=(make(projection),make(projection)))
        gate=IndependentGate(Backend(),capture=Capture(bundle),clock=lambda:now,zone=lambda:'+08:00')
        audit=IndependentAudit(Backend(),clock=lambda:now);reservation=gate.reserve(bundle,grant);audit.seal(bundle,grant,gate,proof)
        rows=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')} for row in plan['rows']]
        body=batch(grant,plan['book_id'],rows,'synthetic-guest','synthetic-config',now,123,now*1000,456,current_zone='+08:00')
        claimed=gate.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config');gate.acknowledge(claimed,{'succ':1})
        store=Mock();store.backend=object();store.read.return_value=(bundle,Receipt(b'synthetic-capture'))
        progress={'timestamp':now,'book':{'bookId':plan['book_id'],'chapterUid':int(plan['chapter_uid']),
            'chapterIdx':plan['chapter_idx'],'chapterOffset':12,'progress':3,'readingTime':20+plan['seconds'],
            'recordReadingTime':0,'ttsTime':0}}
        native_open=Opener(sum(([deepcopy(progress),{'bookId':plan['book_id'],'bookVersion':plan['book_version']},
                                deepcopy(shelf)] for _ in range(3)),[]))
        months=deepcopy(before['months']);month=str(period('monthly',plan['start_time'])[0]);bucket=str(day(plan['start_time']))
        months[month]['readTimes'][bucket]+=plan['seconds'];months[month]['totalReadTime']+=plan['seconds']
        stats_open=Opener([deepcopy(months[key]) for _ in range(3) for key in sorted(months,key=int)])
        shelf_open=Opener([deepcopy(shelf)]*2)
        web=Mock();web.book_id=plan['book_id'];web.chapter=plan['chapter_uid'];web.record=record;web.chapters=record['updated']
        web.shards={'e_0':'synthetic','e_1':'synthetic','e_3':'synthetic'};web._time_catalog_pair=deepcopy(pairs[0])
        web.inspect.return_value={'cloud_position_stable':True,'catalog_stable':True}
        web.request.side_effect=lambda stage,*_args,**_kwargs:deepcopy(progress if stage=='progress_after' else shelf)
        with zipfile.ZipFile(io.BytesIO(base64.b64decode(plan['archive_base64']))) as archive:
            raw=archive.read('OEBPS/weread-position/raw-'+plan['raw_sha256']+'.txt').decode()
        from native_time_bundle_readback import StatisticsReads,ShelfRead
        with patch('verify_native_time_capture.decode_content_shards',return_value=raw):
            result=run(saved={'vid':plan['owner'],'cookies':{'wr_vid':plan['owner'],'wr_skey':'mock_key'}},grant=grant,
                store=store,gate=gate,audit=audit,current=lambda:True,clock=lambda:now,sleep=lambda _:None,
                web_factory=lambda _book:web,native_factory=lambda grant,plan,current,clock:BoundNative(grant,plan,current,clock,native_open),
                statistics_factory=lambda grant,months,current:StatisticsReads(grant,months,current,stats_open),
                shelf_factory=lambda grant,current:ShelfRead(grant,current,shelf_open))
        self.assertEqual(result['result'],'READBACK_MATCH');self.assertFalse(result['real_accounting_verified'])
        self.assertEqual(len(native_open.requests),9);self.assertEqual(len(stats_open.requests),3*len(months))
        self.assertEqual(len(shelf_open.requests),2);self.assertEqual(gate.read()[0]['phase'],'acknowledged')


if __name__=='__main__':unittest.main()
