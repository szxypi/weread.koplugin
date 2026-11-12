"""Read-only cloud UI and private evidence, without real credentials or network."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import hashlib
import io
import json
import subprocess
import unittest
from unittest.mock import patch,Mock
from owner_cloud_source_contract import FLAGS,FRAME,validate_payload,decode,decode_runner,compare
from test_owner_reading import stage as reading_stage
from test_native_reader_trial import payload as reader_payload
import verify_owner_cloud_source as task
from run_owner_cloud_source import reader_stage

RAW='Synthetic original for native raw source validation. '*8


def payload():
    v=reader_payload();t=v.pop('native_reader_trial');v.pop('native_grant');v['cloud_mock_port']=v.pop('reader_mock_port')
    v['raw_cloud_preview']={k:deepcopy(t['plan'][k]) for k in ('baseline','target')}
    v['source_raw_sha256']=hashlib.sha256(RAW.encode()).hexdigest();return v


def private(value):
    p=dict(book_id=value['book_id'],chapter_uid=value['chapter_uid'],chapter_offset=value['raw_cloud_preview']['baseline']['chapter_offset'],
           file_id='a'*64,book_version=7,raw_sha256=value['source_raw_sha256'],render_path='OEBPS/text/chapter.xhtml',basis='raw_txt_utf16',upload_verified=False)
    return dict(position=deepcopy(p),checkpoint=deepcopy(p))


def stage(mode='live'):
    r=reading_stage(mode);a={key:False for key in FLAGS}
    required={'raw_target','parent_native_guard'}|({'offline_checkpoint','offline_local_only'} if mode=='reopen' else FLAGS-{'offline_checkpoint','offline_local_only'})
    for k in required:a[k]=True
    a.update(native_denied=0,failed_line=0);r['cloud_source']=a;return r


def envelope(mode='live'):
    return dict(report=stage(mode),cookies=dict(wr_vid='900000',wr_skey='mock_key'),candidate_private=private(payload()))


def runner():
    return dict(report=dict(result='PASS',profile_removed=True,stages=[stage(),stage('reopen')],installed=dict(files=284,bytes_match=True),error='none'),
                cookies=dict(wr_vid='900000',wr_skey='mock_key'),candidate_private=[private(payload()),private(payload())])


def frame(value):return FRAME+json.dumps(value).encode()


class CloudSourceTests(unittest.TestCase):
    def test_default_never_loads_credentials_or_launches_reader(self):
        with patch.object(task,'SessionStore') as web,patch.object(task,'NativeSessionStore') as native,\
             patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        for item in (web,native,child):item.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_explicit_session_command_pair_required(self):
        for args in (['--saved-session'],['--lua-command','forbidden'],['--book-from-retired-close']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

    def test_no_native_grant_or_write_permit_accepted_in_private_input(self):
        validate_payload(payload(),12345)
        for key in ('native_grant','permit_writes','native_reader_trial','native_recovery'):
            v=payload();v[key]={}
            with self.assertRaises(ValueError):validate_payload(v,12345)

    def test_exact_book_chapter_and_source_format_binding(self):
        for change in ({'book_id':'900002'},{'chapter_uid':'3'},{'source_format':'web_xhtml'},{'source_raw_sha256':'bad'}):
            v=payload();v.update(change)
            with self.assertRaises(ValueError):validate_payload(v,12345)
        v=payload();v['raw_cloud_preview']['target']['chapter_offset']+=1
        with self.assertRaises(ValueError):validate_payload(v,12345)

    def test_live_choice_and_offline_local_state_have_different_proofs(self):
        for mode in ('live','reopen'):self.assertEqual(decode(frame(envelope(mode)),'900000',mode),envelope(mode))
        decode_runner(frame(runner()),'900000');compare(runner()['candidate_private'],payload(),RAW)

    def test_live_success_requires_worker_verified_checkpoint_and_cleared_intent(self):
        for key in ('cloud_choice','background_worker','raw_target','sync_verified','pending_cleared','checkpoint_saved','truthful_notice','parent_native_guard'):
            v=envelope();v['report']['cloud_source'][key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):decode(frame(v),'900000','live')

    def test_offline_never_claims_a_new_cloud_sync_or_http(self):
        for key in ('cloud_choice','sync_verified','background_worker'):
            v=envelope('reopen');v['report']['cloud_source'][key]=True
            with self.assertRaises(ValueError):decode(frame(v),'900000','reopen')
        v=envelope('reopen');v['report']['requests'][1]=1
        with self.assertRaises(ValueError):decode(frame(v),'900000','reopen')

    def test_source_receipt_cannot_become_an_upload_grant(self):
        v=envelope();v['candidate_private']['position']['upload_verified']=True
        with self.assertRaises(ValueError):decode(frame(v),'900000','live')
        for change in ({'basis':'filtered_xhtml_utf16'},{'chapter_offset':True},{'raw_sha256':'bad'},{'extra':'private'}):
            v=envelope();v['candidate_private']['checkpoint'].update(change)
            with self.assertRaises(ValueError):decode(frame(v),'900000','live')

    def test_native_attempt_or_wrong_report_types_fail(self):
        for key,bad in (('native_denied',1),('native_denied',False),('failed_line',True),('sync_verified',1)):
            v=envelope();v['report']['cloud_source'][key]=bad
            with self.assertRaises(ValueError):decode(frame(v),'900000','live')

    def test_private_source_must_match_independent_raw_offset_and_both_processes(self):
        for field,bad in (('book_id','900002'),('chapter_uid','3'),('chapter_offset',999),('raw_sha256','b'*64)):
            rows=runner()['candidate_private'];rows[1]['checkpoint'][field]=bad
            with self.assertRaises(ValueError):compare(rows,payload(),RAW)
        rows=runner()['candidate_private'];rows[1]['position']['file_id']='b'*64
        with self.assertRaises(ValueError):compare(rows,payload(),RAW)

    def test_runner_cannot_hide_missing_cleanup_or_missing_process(self):
        for change in ({'profile_removed':False},{'stages':[stage()]},{'installed':dict(files=284,bytes_match=False)}):
            v=runner();v['report'].update(change)
            with self.assertRaises(ValueError):decode_runner(frame(v),'900000')

    def test_ambiguous_frames_extra_private_fields_and_incomplete_proof(self):
        for raw in (b'private',FRAME+frame(envelope()),b'x'*(2*1024*1024+1)):
            with self.assertRaises(ValueError):decode(raw,'900000','live')
        for where in ('root','nested'):
            v=envelope();(v if where=='root' else v['report']['cloud_source'])['summary']='private'
            with self.assertRaises(ValueError):decode(frame(v),'900000','live')
        v=envelope();v['report']['result']='UNVERIFIED';v['report']['cloud_source']['sync_verified']=False
        self.assertEqual(decode(frame(v),'900000','live')['report']['result'],'UNVERIFIED')

    def test_reader_timeout_reaps_all_worker_groups_through_existing_supervisor(self):
        child=Mock();child.communicate.side_effect=subprocess.TimeoutExpired('synthetic',180)
        with patch('run_owner_cloud_source.subprocess.Popen',return_value=child),patch('run_owner_cloud_source.stop_reader') as stop:
            with self.assertRaises(subprocess.TimeoutExpired):reader_stage(['synthetic'],{},b'private',None)
        stop.assert_called_once_with(child)


if __name__=='__main__':unittest.main()
