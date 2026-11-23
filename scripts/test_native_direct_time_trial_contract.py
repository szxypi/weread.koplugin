"""Mutation and replay boundaries for a direct-chapter time trial."""
import copy
import unittest

from native_direct_time_trial_contract import day,validate_claim,validate_selection
from native_direct_time_trial_store import Intent
from native_time_bundle_native_record import point_hash
from native_time_bundle_selection import native_digest
from native_time_capture_evidence import account_key
from readtime_upload_model import batch
from test_cb_fixture_position_transport import MemoryBackend
from verify_native_time_capture import full_point
from verify_native_statistics import period


def fixture():
    now=1700007200;grant=dict(vid='900000',deviceId='eink334691225'+'1'*19,
        accessToken='synthetic-access',refreshToken='synthetic-refresh')
    expected=dict(book_id='42',uid='7',version=7,source_sha256='b'*64)
    row=dict(id=1,book_id='42',start_time=now-8,duration=6,time_zone='+08:00',book_version=7,
        file_id='a'*64,version_source='native_direct')
    part=dict(row_id=1,start_time=row['start_time'],duration=6)
    protocol=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')}]
    selection=dict(book_id='42',file_id='a'*64,book_version=7,time_zone='+08:00',seconds=6,rows=[row],parts=[part],
        protocol_rows=protocol,rows_hash=native_digest([row]),parts_hash=native_digest([part]),native_direct=True,current_day=True)
    reference=dict(kind='native_direct',file='/dev/shm/weread-direct-time-trial-abc/profile/weread/native-reader-v1/a/b.epub',
        chapter_uid='7',source_sha256='b'*64)
    point=full_point(dict(bookId='42',chapterUid=7,chapterIdx=0,chapterOffset=3,progress=10,summary='fixture'),'42','native')
    month=period('monthly',now)[0]
    baseline=dict(native_point=point,web_point=point,counts=dict(readingTime=10,recordReadingTime=0,ttsTime=0),
        shelf_hash='c'*64,months={str(month):dict(baseTime=month,readTimes={},totalReadTime=0,readDays=0)},
        guest='synthetic-guest',config_token='synthetic-config')
    body=batch(grant,'42',protocol,baseline['guest'],baseline['config_token'],now,123,now*1000,456,current_zone='+08:00')
    source=dict(kind='native_direct',ref=reference,book_id='42',chapter_uid='7',chapter_idx=0,file_id='a'*64,
        book_version=7,source_sha256='b'*64,catalog_stamp='d'*64,account=account_key(grant['vid']))
    metadata=dict(protocol='native-current-time-cst-v1',position_contract='historical-time-point-presence-v1',book_id='42',
        file_id='a'*64,book_version=7,seconds=6,day=day(now),created_at=now,device_hash=native_digest(grant['deviceId']),
        source=source,native_hash=point_hash(point,'42'),web_hash=point_hash(point,'42'),counts=baseline['counts'],
        shelf_hash=baseline['shelf_hash'],months=baseline['months'],request_hash=native_digest(body))
    record=dict(attempt='offtime-v1:'+'1'*32,account=source['account'],phase='claimed',metadata=metadata,rows=[row],
        request_hash=metadata['request_hash'],created=now)
    event=dict(kind='claim',body=body,selection=selection,record=record)
    return now,grant,expected,selection,reference,baseline,event


class DirectTimeContractTests(unittest.TestCase):
    def test_selection_binds_source_and_whole_captured_intervals(self):
        now,grant,expected,selection,reference,baseline,event=fixture()
        self.assertIs(validate_selection(selection,reference,expected,6,now),selection)
        for change in ('book','seconds','time','parts','source','path'):
            s=copy.deepcopy(selection);r=copy.deepcopy(reference)
            if change=='book':s['book_id']='43'
            elif change=='seconds':s['seconds']=7
            elif change=='time':s['rows'][0]['start_time']-=200;s['rows_hash']=native_digest(s['rows'])
            elif change=='parts':s['parts'][0]['duration']=5;s['parts_hash']=native_digest(s['parts'])
            elif change=='source':r['source_sha256']='f'*64
            else:r['file']='/tmp/untrusted.epub'
            with self.subTest(change=change),self.assertRaises(ValueError):validate_selection(s,r,expected,6,now)

    def test_claim_rejects_mutated_request_baseline_or_identity(self):
        now,grant,expected,selection,reference,baseline,event=fixture()
        self.assertTrue(validate_claim(event,selection,reference,expected,baseline,grant,now))
        for change in ('body','source','counts','shelf','phase','rows','record_hash'):
            e=copy.deepcopy(event)
            if change=='body':e['body']['books'][0]['readingTime']=7
            elif change=='source':e['record']['metadata']['source']['source_sha256']='f'*64
            elif change=='counts':e['record']['metadata']['counts']['readingTime']+=1
            elif change=='shelf':e['record']['metadata']['shelf_hash']='e'*64
            elif change=='phase':e['record']['phase']='prepared'
            elif change=='rows':e['record']['rows'][0]['duration']=5
            else:e['record']['request_hash']='e'*64
            with self.subTest(change=change),self.assertRaises(ValueError):
                validate_claim(e,selection,reference,expected,baseline,grant,now)

    def test_claim_is_durable_and_never_reusable(self):
        _,_,_,selection,_,baseline,event=fixture();backend=MemoryBackend();store=Intent(backend=backend)
        plan=dict(selection=selection,record=event['record'],body=event['body'],baseline=baseline)
        receipt=store.claim(plan,now=1700007200)
        self.assertEqual(store.read()[0]['phase'],'claimed')
        with self.assertRaises(Exception):store.claim(plan,now=1700007200)
        with self.assertRaises(Exception):store.advance(b'old','acknowledged')
        receipt=store.advance(receipt,'acknowledged');receipt=store.advance(receipt,'verified')
        self.assertEqual(store.read()[0]['phase'],'verified')
        with self.assertRaises(Exception):store.advance(receipt,'acknowledged')
        with self.assertRaises(Exception):store.claim(plan,now=1700007200)


if __name__=='__main__':unittest.main()
