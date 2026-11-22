"""Offline reconnect keeps its own claim, source and readback boundaries."""
from copy import deepcopy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import Mock,patch

import native_reader_trial_broker as broker
from native_reader_trial_contract import validate_payload
from secure_native_reader_trial import NativeReaderTrialStore,NativeReconnectTrialStore,validate_reconnect_plan
from secure_native_txt_roundtrip import NativeTxtRoundtripStore
from secure_weread_session import StoreError
from test_native_reader_trial import Child,events,payload,result
from test_secure_native_session import Backend
from native_txt_read_model import body
from native_reader_fixture import GRANT
import time
import verify_native_reader_trial as task


def initial(armed=False,prepare=True):
    value=payload(armed,prepare);trial=value['native_reader_trial'];trial['offline_reconnect']=True
    trial['plan']['protocol']=NativeReconnectTrialStore.protocol
    return value


def sequence(value,offset=105):
    trial=value['native_reader_trial'];plan=deepcopy(trial['plan'])
    plan['target'].update(chapter_offset=offset,summary='z'*30,raw_percent=23)
    metadata=dict(book_id='900001',before=deepcopy(plan['baseline']),desired=deepcopy(plan['target']),
        counts=deepcopy(plan['counts']),version=plan['version'],shelf_sha256=trial['native_shelf_sha256'],
        source_sha256=plan['source_sha256'],file_id='a'*64,basis='raw_txt_utf16')
    items=[('STEP',dict(kind='plan',seq=1,metadata=metadata,reader_percent=23))]
    for seq in ((1,2) if trial['armed'] else (1,)):
        dto=body(GRANT,plan['target' if seq==1 else 'baseline'],plan['version'],trial['guest'],int(time.time()),123,trial['time_zone'])
        items.append(('STEP',dict(kind='claim' if trial['armed'] else 'dry_body',seq=seq,body=dto)))
        if trial['armed']:items.extend([('STEP',dict(kind='ack',seq=seq)),('STEP',dict(kind='verified',seq=seq))])
    output=result(trial['armed']);output['stage']['native_reader_trial'].update(offline_reconnect_verified=True,reconnect_diagnostic='none')
    return items+[('RESULT',output)],plan


class NativeReconnectTests(unittest.TestCase):
    def run_broker(self,value,store,items,*,prepare,target_check=lambda p:p['summary']=='z'*30,after=None):
        frames=Mock();frames.next.side_effect=items;child=Child();report={}
        with patch.object(broker.subprocess,'Popen',return_value=child),patch.object(broker,'Frames',return_value=frames),\
             patch.object(broker,'reply'),patch.object(broker,'stop'):
            try:broker.execute(value,['synthetic'],store,report,prepare=prepare,target_check=target_check,after=after)
            except Exception:report['stopped']=True
        return report

    def test_prepare_binds_actual_page_and_never_claims(self):
        value=initial();items,expected=sequence(value);store=NativeReconnectTrialStore(Backend())
        validate_payload(value,False,12345)
        report=self.run_broker(value,store,items,prepare=True)
        state,_=store.read();self.assertEqual(state['phase'],'prepared');self.assertEqual(state['posts'],0)
        self.assertEqual(state['plan'],expected);self.assertEqual(report['synthetic_posts'],0)

    def test_independently_checked_two_step_restore(self):
        value=initial(True,False);items,plan=sequence(value);value['native_reader_trial']['plan']=deepcopy(plan)
        store=NativeReconnectTrialStore(Backend());store.reserve(plan);verified=[]
        report=self.run_broker(value,store,items,prepare=False,after=lambda seq,p:verified.append((seq,p['target']['chapter_offset'])))
        self.assertEqual(report['result'],'NATIVE_READER_TRIAL_VERIFIED');self.assertEqual(verified,[(1,105),(2,105)])
        self.assertEqual(store.read()[0]['phase'],'retired');self.assertEqual(report['synthetic_posts'],2)
        with self.assertRaises(StoreError):store.reserve(plan)

    def test_source_mismatch_or_changed_scope_stops_before_claim(self):
        for change in ('source','baseline','chapter','count','percentage'):
            value=initial();items,_=sequence(value);store=NativeReconnectTrialStore(Backend())
            metadata=items[0][1]['metadata']
            if change=='baseline':metadata['before']['chapter_offset']+=1
            elif change=='chapter':metadata['desired']['chapter_idx']+=1
            elif change=='count':metadata['counts']['readingTime']+=1
            elif change=='percentage':metadata['desired']['raw_percent']=1.5
            report=self.run_broker(value,store,items,prepare=True,target_check=lambda _p:change!='source')
            self.assertTrue(report['stopped']);self.assertIsNone(store.read()[0])

    def test_failed_independent_readback_never_restores_or_replays(self):
        value=initial(True,False);items,plan=sequence(value);value['native_reader_trial']['plan']=deepcopy(plan)
        store=NativeReconnectTrialStore(Backend());store.reserve(plan)
        def failed(_seq,_plan):raise ValueError('synthetic independent readback failure')
        report=self.run_broker(value,store,items,prepare=False,after=failed)
        self.assertTrue(report['stopped']);self.assertEqual(store.read()[0]['phase'],'advance_acknowledged')
        self.assertEqual(store.read()[0]['posts'],1)
        with self.assertRaises(StoreError):store.reserve(plan)

    def test_old_scopes_and_invalid_targets_stay_separate(self):
        value=initial();plan=value['native_reader_trial']['plan'];backend=Backend();store=NativeReconnectTrialStore(backend)
        store.reserve(plan)
        for old in (NativeReaderTrialStore(backend),NativeTxtRoundtripStore(backend,native=True)):
            with self.assertRaises(StoreError):old.read()
        for update in ({'chapter_offset':plan['baseline']['chapter_offset']},{'summary':'too short'}, {'raw_percent':True}):
            p=deepcopy(plan);p['target'].update(update)
            with self.assertRaises(StoreError):validate_reconnect_plan(p)

    def test_fresh_inspection_only_reads_a_retired_scope(self):
        plan=initial()['native_reader_trial']['plan']
        for phase,expected_checks in (('retired',2),('advance_pending',0)):
            saved={'vid':'900000','cookies':{'wr_vid':'900000','wr_skey':'mock_key'}}
            session=Mock();session.load.side_effect=lambda:deepcopy(saved)
            native_store=Mock();native_store.load.return_value=deepcopy(GRANT)
            state={'phase':phase,'posts':2 if phase=='retired' else 1,'plan':deepcopy(plan)}
            journal=Mock();journal.read.return_value=(state,None)
            web=Mock();web.vid='900000';web.book_id='900001';web.authenticated=True
            web.find_sample.return_value=True;web.report={'stages':[]};web.sample={}
            native=Mock();native.report={'stages':[]};native.posts=0
            with patch('verify_native_thought_trial.other_pending',return_value=False),\
                 patch.object(task,'SessionStore',return_value=session),patch.object(task,'NativeSessionStore',return_value=native_store),\
                 patch.object(task,'NativeReconnectTrialStore',return_value=journal),patch.object(task,'ReadingSource',return_value=web),\
                 patch.object(task,'Reads',return_value=native),patch.object(task,'save_refreshed_web_session'),\
                 patch.object(task,'check') as check,redirect_stdout(io.StringIO()) as out:
                code=task.main(['--saved-session','--inspect','--offline-reconnect'])
            report=json.loads(out.getvalue());self.assertEqual(check.call_count,expected_checks)
            self.assertEqual(code,0 if phase=='retired' else 1);self.assertEqual(report['account_data_posts'],0)
            if phase=='retired':self.assertEqual(report['independent_readbacks'],2)


if __name__=='__main__':unittest.main()
