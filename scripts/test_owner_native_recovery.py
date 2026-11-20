"""No Keychain/network: actual-401 CAS, no replay and private-pipe boundaries."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import io
import json
import time
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch,Mock
from native_reader_fixture import GRANT
from native_source_recovery_contract import FLAGS,validate_payload,validate_result
from native_source_recovery_broker import Broker,check_refresh,check_metadata,execute
from secure_native_session import NativeSessionStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_native_reader_trial import payload as old_payload
from test_native_reader_trial import Child
from test_owner_reading import stage as reading_stage
from test_native_reader_recovery import refresh
from native_txt_read_model import body
import verify_owner_native_recovery as task


def payload():
    value=old_payload();old=value.pop('native_reader_trial')
    value['native_recovery']={k:deepcopy(old['plan'][k]) for k in ('baseline','target')}
    value['native_recovery'].update(rpc_token='b'*32,time_zone='+08:00');return value


def observation(value):
    return dict(point=deepcopy(value['native_recovery']['baseline']),counts=dict(readingTime=10,recordReadingTime=20,ttsTime=0),
                version=0,shelf_sha256='c'*64,guest='5ecdcfd7f',book_count=1)


def metadata(value,obs):
    return dict(book_id=value['book_id'],before=deepcopy(obs['point']),desired=deepcopy(value['native_recovery']['target']),
                counts=deepcopy(obs['counts']),version=obs['version'],shelf_sha256=obs['shelf_sha256'],source_sha256=value['source_raw_sha256'],
                file_id='a'*64,basis='raw_txt_utf16')


def result(no_expiry=False):
    stage=reading_stage();a={k:not no_expiry for k in FLAGS}
    a.update(source_reference=True,manual_controls=True,source_plan=True,native_file_audit=True,no_expiry=no_expiry,
             phase='complete',native_gets=3 if no_expiry else 10,authentication_posts=int(not no_expiry),blocked_posts=int(not no_expiry),
             expired_responses=int(not no_expiry),native_denied=0,last_native_status=200,source_preparations=1 if no_expiry else 2,failed_line=0)
    stage['native_recovery']=a
    return dict(result='PASS',profile_removed=True,installed=dict(files=284,bytes_match=True),stage=stage,
                cookies=dict(wr_vid='900000',wr_skey='mock_key'))


class OwnerRecoveryTests(unittest.TestCase):
    def fixture(self):
        value=payload();obs=observation(value);store=NativeSessionStore(Backend());store.save(GRANT,GRANT['vid'],verified=True)
        expired=Mock(return_value=True);claimed=Mock()
        broker=Broker(value,store,verify_expiry=expired,observe=lambda grant:deepcopy(obs),claim=claimed)
        fresh=dict(GRANT,accessToken='synthetic-renewed-access')
        events=[dict(kind='expiry',seq=1,url='https://i.weread.qq.com/book/info?bookId=900001',status=401),
                dict(kind='claim',seq=2,body=refresh()),dict(kind='verified',seq=3,credentials=fresh,book_count=1),
                dict(kind='plan',seq=4,metadata=metadata(value,obs),reader_percent=value['native_recovery']['target']['raw_percent'])]
        events.append(dict(kind='data',seq=5,body=body(fresh,events[3]['metadata']['desired'],0,obs['guest'],int(time.time()),123,'+08:00')))
        return value,obs,store,broker,events,expired,claimed

    def test_defaults_never_load_keychain_or_launch_reader(self):
        with patch.object(task,'SessionStore') as web,patch.object(task,'NativeSessionStore') as native,patch.object(task,'execute') as child,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        for item in (web,native,child):item.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_explicit_session_runner_marker_pair_required(self):
        for args in (['--saved-session'],['--native-ui-command','forbidden'],['--no-expiry'],['--once-marker','/tmp/forbidden']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

    def test_existing_real_once_marker_stops_before_keychain_or_reader(self):
        with tempfile.TemporaryDirectory() as directory:
            marker=Path(directory)/'consumed.json';marker.write_text('{"state":"consumed"}')
            with patch.object(task,'SessionStore') as web,patch.object(task,'NativeSessionStore') as native,\
                 patch.object(task,'execute') as child,redirect_stdout(io.StringIO()) as output:
                self.assertEqual(task.main(['--saved-session','--once-marker',str(marker),'--native-ui-command','forbidden']),1)
            for item in (web,native,child):item.assert_not_called()
            self.assertEqual(json.loads(output.getvalue())['reason'],'source_recovery/consumed')

    def test_full_real_sdk_sequence_requires_durable_keychain_before_http_permission(self):
        value,obs,store,b,events,expired,claimed=self.fixture()
        b.handle(events[0]);b.handle(events[1]);claimed.assert_called_once()
        with self.assertRaisesRegex(StoreError,'native_renewal_unconfirmed'):store.load(value['vid'])
        b.handle(events[2]);self.assertEqual(store.load(value['vid']),events[2]['credentials'])
        for event in events[3:]:b.handle(event)
        b.finish(result());self.assertEqual((b.posts,b.blocked,b.phase),(1,1,'blocked'))

    def test_no_expiry_stops_without_claim_or_any_grant_mutation(self):
        value,obs,store,b,events,expired,claimed=self.fixture();before=store.backend.data
        b.handle(dict(kind='no_expiry',seq=0,metadata=metadata(value,obs),reader_percent=value['native_recovery']['target']['raw_percent']))
        b.finish(result(True));self.assertEqual(store.backend.data,before)
        expired.assert_not_called();claimed.assert_not_called();self.assertEqual((b.posts,b.blocked),(0,0))

    def test_claim_without_new_independent_expiry_is_rejected(self):
        for observed in (False,None,1):
            value,obs,store,b,events,expired,claimed=self.fixture();expired.return_value=observed
            with self.assertRaises(ValueError):b.handle(events[0])
            with self.assertRaises(ValueError):b.handle(events[1])
            claimed.assert_not_called();self.assertEqual(store.load(value['vid']),GRANT)

    def test_only_whitelisted_read401_can_witness_expiry(self):
        for change in ({'status':True},{'status':500},{'url':'https://i.weread.qq.com/book/read'}):
            value,obs,store,b,events,expired,claimed=self.fixture();events[0].update(change)
            with self.assertRaises(ValueError):b.handle(events[0])
            expired.assert_not_called()

    def test_observe_only_forbids_authorization_even_with_a_new_true401(self):
        value,obs,store,b,events,expired,claimed=self.fixture();b.allow_renewal=False;before=store.backend.data
        b.handle(events[0])
        with self.assertRaisesRegex(ValueError,'source_recovery/renewal_disabled'):b.handle(events[1])
        claimed.assert_not_called();self.assertEqual(store.backend.data,before);self.assertEqual(b.posts,0)

    def test_stale_expiry_or_duplicate_claim_never_replays(self):
        value,obs,store,b,events,expired,claimed=self.fixture();b.handle(events[0]);b.expired_at-=31
        with self.assertRaises(ValueError):b.handle(events[1])
        value,obs,store,b,events,expired,claimed=self.fixture();b.handle(events[0]);b.handle(events[1])
        with self.assertRaises(ValueError):b.handle(events[1])
        with self.assertRaises(StoreError):store.load(value['vid'])
        claimed.assert_called_once()

    def test_unknown_receipt_keeps_keychain_pending_and_prohibits_data(self):
        value,obs,store,b,events,expired,claimed=self.fixture()
        for event in events[:2]:b.handle(event)
        for event in events[3:]:
            with self.assertRaises(ValueError):b.handle(event)
        with self.assertRaises(StoreError):store.begin_renewal(value['vid'])
        self.assertEqual(b.posts,1);self.assertEqual(b.blocked,0)

    def test_foreign_owner_or_device_is_never_saved(self):
        for field,bad in (('vid','900099'),('deviceId','2'*32)):
            value,obs,store,b,events,expired,claimed=self.fixture()
            for event in events[:2]:b.handle(event)
            events[2]['credentials'][field]=bad
            with self.assertRaises(ValueError):b.handle(events[2])
            with self.assertRaises(StoreError):store.load(value['vid'])

    def test_verified_new_grant_is_retained_if_later_plan_or_process_fails(self):
        value,obs,store,b,events,expired,claimed=self.fixture()
        for event in events[:3]:b.handle(event)
        with self.assertRaises(ValueError):b.finish(result())
        self.assertEqual(store.load(value['vid']),events[2]['credentials'])
        with self.assertRaises(ValueError):b.handle(events[1])

    def test_full_refresh_fields_signature_and_strict_types(self):
        for change in ({'extra':'private'},{'signature':'0'*64},{'random':True},{'inBackground':False},
                       {'kickType':True},{'deviceType':True},{'deviceId':'2'*32},{'timestamp':1},{'refreshToken':'wrong'}):
            dto=refresh();dto.update(change)
            with self.assertRaises(ValueError):check_refresh(dto,GRANT)

    def test_full_source_point_counts_version_and_reader_percent_are_bound(self):
        value,obs,store,b,events,expired,claimed=self.fixture();m=metadata(value,obs);percent=m['desired']['raw_percent']
        for change in ({'source_sha256':'0'*64},{'version':1},{'file_id':'bad'},{'counts':{}},{'basis':'filtered_xhtml_utf16'}):
            bad=deepcopy(m);bad.update(change)
            with self.assertRaises(ValueError):check_metadata(bad,value,obs,percent)
        with self.assertRaises(ValueError):check_metadata(m,value,obs,True)

    def test_zero_time_complete_data_dto_checked_before_blocking(self):
        for change in ({'summary':'guessed'},{'readingTime':1},{'bookVersion':1},{'hours':[1]},{'signature':'0'*64},{'random':True}):
            value,obs,store,b,events,expired,claimed=self.fixture()
            for event in events[:4]:b.handle(event)
            events[4]['body'].update(change)
            with self.assertRaises(ValueError):b.handle(events[4])
            self.assertEqual(b.blocked,0)

    def test_final_evidence_rejects_missing_audit_extra_private_fields_and_invented_renewal(self):
        validate_result(result(),'900000');validate_payload(payload(),12345)
        for key in ('renewal_saved','fresh_source','native_file_audit','dispatch_blocked','sqlite_before_block'):
            value=result();value['stage']['native_recovery'][key]=False
            with self.assertRaises(ValueError):validate_result(value,'900000')
        value=result(True);value['stage']['native_recovery']['authentication_posts']=1
        with self.assertRaises(ValueError):validate_result(value,'900000')
        for where in ('root','nested'):
            value=result();(value if where=='root' else value['stage']['native_recovery'])['summary']='private'
            with self.assertRaises(ValueError):validate_result(value,'900000')

    def test_duplex_supervision_records_only_closed_report_and_always_reaps_child(self):
        value,obs,store,b,events,expired,claimed=self.fixture();child=Child();frames=Mock()
        frames.next.side_effect=[('STEP',item) for item in events]+[('RESULT',result())];report={}
        with patch('native_source_recovery_broker.subprocess.Popen',return_value=child),\
             patch('native_source_recovery_broker.Frames',return_value=frames),patch('native_source_recovery_broker.reply'),\
             patch('native_source_recovery_broker.stop') as stop:
            execute(value,['synthetic'],b,report)
        stop.assert_called_once_with(child)
        self.assertEqual(report['account_data_posts'],0);self.assertEqual(report['authentication_posts_claimed'],1)
        self.assertNotIn('cookies',report['native_ui']);self.assertTrue(report['keychain_new_grant_saved'])

    def test_lost_duplex_receipt_does_not_release_claim_or_repeat_authorization(self):
        value,obs,store,b,events,expired,claimed=self.fixture();child=Child();frames=Mock()
        frames.next.side_effect=[('STEP',events[0]),('STEP',events[1]),ValueError('source_recovery/lost')];report={}
        with patch('native_source_recovery_broker.subprocess.Popen',return_value=child),\
             patch('native_source_recovery_broker.Frames',return_value=frames),patch('native_source_recovery_broker.reply'),\
             patch('native_source_recovery_broker.stop') as stop:
            with self.assertRaises(ValueError):execute(value,['synthetic'],b,report)
        stop.assert_called_once_with(child);claimed.assert_called_once()
        with self.assertRaises(StoreError):store.load(value['vid'])
        self.assertEqual(report['account_data_posts'],0);self.assertFalse(report['keychain_new_grant_saved'])


if __name__=='__main__':unittest.main()
