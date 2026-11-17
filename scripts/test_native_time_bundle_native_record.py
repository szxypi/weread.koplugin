"""The native journal must describe the same private preflight and archive."""
import base64
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_audit_store import AuditStore
from native_time_bundle_gate import day
from native_time_bundle_native_record import archive_details,point_hash,validate_record
from native_time_bundle_selection import expected,native_digest
from native_time_bundle_supervisor import NativeBoundSupervisor
from native_time_capture_evidence import account_key
from secure_highlight_trial import Receipt
from test_native_time_bundle_evidence import evidence_fixture,synthetic_catalog
from test_native_time_bundle_gate import fixture,gate
from test_secure_native_session import Backend
from source_currentness import catalog


def make_record(bundle,grant,before,body,path):
    p=bundle['plan'];selection=expected(bundle);meta_hash,raw_bytes=archive_details(p,path)
    source={'expected':{'book_id':p['book_id'],'chapter_uid':p['chapter_uid'],'chapter_idx':p['chapter_idx'],
                        'raw_sha256':p['raw_sha256'],'raw_bytes':raw_bytes},'format':p['format'],
            'metadata_hash':meta_hash,'ref':{'file':str(path),'chapter_uid':p['chapter_uid'],'chapter_idx':p['chapter_idx']},
            'catalog_stamp':catalog([synthetic_catalog(p)],p['book_id'],p['chapter_uid'])[1]}
    metadata={'protocol':'native-historical-time-cst-v1','position_contract':'historical-time-point-presence-v1',
              'book_id':p['book_id'],'file_id':p['file_id'],'book_version':p['book_version'],'seconds':p['seconds'],
              'day':day(p['start_time']),'created_at':body['books'][0]['timestamp'],'device_hash':native_digest(grant['deviceId']),
              'source':source,'native_hash':point_hash(before['snapshot']['point'],p['book_id']),
              'web_hash':point_hash(before['snapshot']['web_point'],p['book_id']),
              'counts':deepcopy(before['snapshot']['counts']),'shelf_hash':before['snapshot']['shelf'],
              'months':deepcopy(before['months']),'request_hash':native_digest(body)}
    rows=deepcopy(selection['rows'])
    for row in rows:row['id']+=100
    return {'attempt':'offtime-v1:'+'a'*32,'account':account_key(p['owner']),'phase':'claimed','metadata':metadata,
            'rows':rows,'request_hash':metadata['request_hash'],'created':body['books'][0]['timestamp']}


class NativeRecordTests(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory();self.addCleanup(self.folder.cleanup)
        self.bundle,self.grant,self.before,_report,self.now,self.evidence=evidence_fixture()
        _b,_g,self.body,_n=fixture();self.selection=expected(self.bundle)
        self.path=Path(self.folder.name)/'source.epub'
        self.path.write_bytes(base64.b64decode(self.bundle['plan']['archive_base64']))
        self.record=make_record(self.bundle,self.grant,self.before,self.body,self.path)

    def check(self):
        return validate_record(self.bundle,self.grant,self.evidence,self.selection,self.body,self.record,self.path,self.now)

    def test_matching_record_allows_regenerated_row_ids(self):
        self.assertTrue(self.check())
        self.assertNotEqual(self.record['rows'][0]['id'],self.selection['rows'][0]['id'])

    def test_each_unrelated_change_is_rejected(self):
        for key in ('native_hash','web_hash','shelf_hash','counts','months','source','source_metadata','catalog','file',
                    'device','seconds','day','stamp','request','row','account','phase','extra'):
            with self.subTest(key=key):
                original=deepcopy(self.record);m=self.record['metadata']
                if key in ('native_hash','web_hash','shelf_hash'):m[key]='f'*64
                elif key=='counts':m['counts']['ttsTime']+=1
                elif key=='months':next(iter(m['months'].values()))['totalReadTime']+=1
                elif key=='source':m['source']['expected']['raw_sha256']='f'*64
                elif key=='source_metadata':m['source']['metadata_hash']='f'*64
                elif key=='catalog':m['source']['catalog_stamp']='f'*64
                elif key=='file':m['source']['ref']['file']+='x'
                elif key=='device':m['device_hash']='f'*64
                elif key=='seconds':m['seconds']+=1
                elif key=='day':m['day']+=86400
                elif key=='stamp':m['created_at']+=1
                elif key=='request':self.record['request_hash']='f'*64
                elif key=='row':self.record['rows'][0]['duration']+=1
                elif key=='account':self.record['account']='f'*20
                elif key=='phase':self.record['phase']='prepared'
                else:m['extra']=True
                with self.assertRaises(ValueError):self.check()
                self.record=original

    def test_replaced_archive_or_symlink_is_rejected(self):
        self.path.write_bytes(b'replaced')
        with self.assertRaisesRegex(ValueError,'native_record/archive'):self.check()
        self.path.unlink();self.path.symlink_to(Path(self.folder.name)/'missing')
        with self.assertRaisesRegex(ValueError,'native_record/archive'):self.check()

    def test_native_record_must_be_current_and_on_request_day(self):
        for now in (self.now-1,self.now+30,self.now+86400):
            with self.subTest(now=now),self.assertRaises(ValueError):
                validate_record(self.bundle,self.grant,self.evidence,self.selection,self.body,self.record,self.path,now)

    def test_supervisor_rejects_mismatch_before_reservation_and_after_claim(self):
        for stage in ('before','after'):
            with self.subTest(stage=stage):
                self.path.write_bytes(base64.b64decode(self.bundle['plan']['archive_base64']))
                keeper=gate(self.now);store=Mock();store.read.return_value=(self.bundle,Receipt(b'synthetic-capture'))
                audit=AuditStore(Backend(),clock=lambda:self.now)
                supervisor=NativeBoundSupervisor(keeper,store,self.bundle,self.grant,'synthetic-guest','synthetic-config',
                                                  lambda:True,audit_store=audit,evidence=self.evidence)
                supervisor.prepare();supervisor.select(self.selection);claim=keeper.claim
                record=deepcopy(self.record)
                if stage=='before':record['metadata']['counts']['ttsTime']+=1
                def replace_archive(*args,**kwargs):
                    result=claim(*args,**kwargs);self.path.write_bytes(b'replaced');return result
                with patch.object(keeper,'claim',side_effect=replace_archive if stage=='after' else claim):
                    with self.assertRaises(ValueError):supervisor.claim(self.body,self.selection,record,self.path)
                state,_=keeper.read()
                self.assertEqual(state['phase'] if state else None,'claimed' if stage=='after' else None)


if __name__=='__main__':unittest.main()
