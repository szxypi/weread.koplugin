"""The CB worker's durable claim must match exact preflight and archive."""
import base64,tempfile,unittest
from copy import deepcopy
from pathlib import Path

from cb_native_readtime_model import batch
from cb_native_time_bundle_evidence import PreflightEvidence
from cb_native_time_bundle_gate import day
from cb_native_time_bundle_native_record import validate_record
from native_time_bundle_native_record import archive_details,point_hash
from native_time_bundle_selection import expected,native_digest
from native_time_capture_evidence import account_key
from test_cb_native_time_bundle_evidence import fixture


def setup(directory):
    bundle,grant,report,snapshot,months,pairs=fixture();plan=bundle['plan'];now=report['completed_at']
    evidence=PreflightEvidence(bundle,grant,report,snapshot,months,pairs);selection=expected(bundle,imported=True)
    rows=selection['protocol_rows'];body=batch(grant,plan['book_id'],rows,'synthetic-guest','synthetic-config',now,123,
        now*1000,456,current_zone='+08:00',summary=snapshot['native']['summary']['value'])
    path=Path(directory)/'source.epub';path.write_bytes(base64.b64decode(plan['archive_base64']))
    meta_hash,raw_bytes=archive_details(plan,path)
    source=dict(expected=dict(book_id=plan['book_id'],chapter_uid=plan['chapter_uid'],chapter_idx=plan['chapter_idx'],
        raw_sha256=plan['raw_sha256'],raw_bytes=raw_bytes),format=plan['format'],metadata_hash=meta_hash,
        ref=dict(file=str(path),chapter_uid=plan['chapter_uid'],chapter_idx=plan['chapter_idx']),catalog_stamp=evidence.catalog_stamp(bundle,grant))
    request=native_digest(body)
    metadata=dict(protocol='native-historical-time-cst-cb-v1',position_contract='historical-time-point-presence-v1',book_id=plan['book_id'],
        file_id=plan['file_id'],book_version=plan['book_version'],seconds=plan['seconds'],day=day(plan['start_time']),created_at=now,
        device_hash=native_digest(grant['deviceId']),source=source,native_hash=point_hash(snapshot['native'],plan['book_id']),
        web_hash=point_hash(snapshot['web'],plan['book_id']),counts=deepcopy(snapshot['counts']),shelf_hash=snapshot['native_shelf'],
        months=deepcopy(months),request_hash=request)
    record=dict(attempt='offtime-v1:'+'a'*32,account=account_key(plan['owner']),phase='claimed',metadata=metadata,
                rows=deepcopy(selection['rows']),request_hash=request,created=now)
    return bundle,grant,evidence,selection,body,record,path,now


class ImportedNativeRecordTests(unittest.TestCase):
    def test_valid_claim_and_strict_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            args=setup(directory);self.assertTrue(validate_record(*args))
            with self.assertRaises(ValueError):expected(args[0])
    def test_metadata_rows_source_and_request_cannot_change(self):
        for mode in ('phase','account','row','native','web','counts','shelf','month','protocol','source','catalog','body','selection','clock'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                bundle,grant,evidence,selection,body,record,path,now=setup(directory)
                if mode=='phase':record['phase']='prepared'
                elif mode=='account':record['account']='f'*20
                elif mode=='row':record['rows'][0]['duration']+=1
                elif mode=='native':record['metadata']['native_hash']='f'*64
                elif mode=='web':record['metadata']['web_hash']='f'*64
                elif mode=='counts':record['metadata']['counts']['ttsTime']+=1
                elif mode=='shelf':record['metadata']['shelf_hash']='f'*64
                elif mode=='month':next(iter(record['metadata']['months'].values()))['totalReadTime']+=1
                elif mode=='protocol':record['metadata']['protocol']='native-historical-time-cst-v1'
                elif mode=='source':record['metadata']['source']['expected']['raw_sha256']='f'*64
                elif mode=='catalog':record['metadata']['source']['catalog_stamp']='f'*64
                elif mode=='body':body['books'][0]['summary']='changed'
                elif mode=='selection':selection['parts'][0]['duration']+=1
                else:now+=30
                with self.assertRaises(ValueError):validate_record(bundle,grant,evidence,selection,body,record,path,now)
    def test_actual_archive_must_match_and_cannot_be_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle,grant,evidence,selection,body,record,path,now=setup(directory)
            path.write_bytes(path.read_bytes()+b'changed')
            with self.assertRaises(ValueError):validate_record(bundle,grant,evidence,selection,body,record,path,now)
            path.unlink();target=Path(directory)/'other';target.write_bytes(base64.b64decode(bundle['plan']['archive_base64']));path.symlink_to(target)
            with self.assertRaises(ValueError):validate_record(bundle,grant,evidence,selection,body,record,path,now)


if __name__=='__main__':unittest.main()
