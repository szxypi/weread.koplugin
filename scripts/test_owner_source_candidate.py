"""Offline privacy and proof boundaries for the real native candidate tour."""
from contextlib import redirect_stdout,redirect_stderr
import copy
import hashlib
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock,patch

import owner_source_candidate_contract as contract
import verify_owner_source_candidate as task
from test_owner_reading import OWNER,COOKIES,stage,frame
import test_source_upload_candidate as fixture
from source_upload_candidate import project
C=SimpleNamespace(raw=fixture.CandidateTests.raw,chapters=fixture.CandidateTests.chapters,point=fixture.CandidateTests.point)


def records():
    rows=[]
    for name,offset in zip(contract.STAGES,(15,22,16)):
        point=dict(C.point,chapter_offset=offset,file_id='a'*64,book_version=1,raw_sha256=hashlib.sha256(C.raw.encode()).hexdigest(),
                   render_path='OEBPS/text/chapter.xhtml',basis='filtered_xhtml_utf16',upload_verified=False)
        rows.append(dict(stage=name,source=point,candidate=project(C.raw,point,C.chapters,37),
                         legacy=dict(chapter_uid='11',chapter_idx=0,chapter_offset=2,percent=37)))
    return dict(records=rows)


def addon():
    return dict(**dict.fromkeys(contract.FLAGS,True),candidates=3,background_workers=3,legacy_equal_source=0,failed_line=0,preparation_failure=0,
                capture_failure_state=0,capture_failure_reason=0,unexpected_retained=0,capture_origin_kind=0,next_text_visible=0)


def envelope():
    stages=[stage(),stage('reopen')]
    for row in stages:row['source_candidate']=addon()
    return dict(report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,stages=stages,runner_error='none'),
                cookies=COOKIES.copy(),candidate_private=[records(),records()])


def payload():
    return dict(book_id=C.point['book_id'],chapter_uid=C.point['chapter_uid'],source_raw_sha256=hashlib.sha256(C.raw.encode()).hexdigest())


class OwnerCandidateTests(unittest.TestCase):
    def test_default_cannot_load_credentials_network_or_start_native(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'Preflight') as web,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();web.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_no_apply_or_unpaired_execution_mode_exists(self):
        for args in (['--apply'],['--saved-session'],['--lua-command','synthetic'],['--permit-renewal']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

    def test_public_proofs_and_fields_are_strict(self):
        contract.decode(frame(envelope()),OWNER)
        for key in contract.FLAGS:
            value=envelope();value['report']['stages'][0]['source_candidate'][key]=False
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        for key,bad in (('candidates',2),('background_workers',2),('failed_line',1),('legacy_equal_source',True),('text','PRIVATE')):
            value=envelope();value['report']['stages'][0]['source_candidate'][key]=bad
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_two_fresh_processes_cleanup_and_offline_zero_http_are_required(self):
        for key in ('profile_removed','tmpfs_profile'):
            value=envelope();value['report'][key]=False
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        value=envelope();value['report']['stages'].pop();value['candidate_private'].pop()
        with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        for index in range(7):
            value=envelope();value['report']['stages'][1]['requests'][index]=1
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_private_record_order_scope_and_bounds_are_strict(self):
        for key,bad in (('chapter_offset',True),('chapter_uid','other'),('basis','raw_txt_utf16'),('upload_verified',True),
                        ('raw_sha256','bad'),('render_path','other.xhtml')):
            value=envelope();value['candidate_private'][0]['records'][0]['source'][key]=bad
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        for change in ('order','extra','missing','summary','unknown'):
            value=envelope();rows=value['candidate_private'][0]['records']
            if change=='order':rows[0]['stage']='retained'
            if change=='extra':rows.append(copy.deepcopy(rows[0]))
            if change=='missing':rows.pop()
            if change=='summary':rows[0]['candidate']['summary']='A'*21
            if change=='unknown':rows[0]['candidate']['cookie']='PRIVATE'
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_offline_candidates_cannot_change_or_swap_private_frames(self):
        value=envelope();value['candidate_private'][1]['records'][0]['candidate']['summary']='validbutdifferent'
        with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        value=envelope();value['candidate_private'].reverse()
        value['candidate_private'][0]['records'].reverse()
        with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_model_compares_source_summary_index_offset_and_account_book_scope(self):
        value=envelope();contract.compare(value['candidate_private'],C.raw,C.chapters,payload())
        for key,bad in (('summary','validbutincorrect'),('chapter_idx',1),('chapter_offset',22)):
            private=copy.deepcopy(value['candidate_private'])
            private[0]['records'][0]['candidate'][key]=bad
            if key=='chapter_offset':private[0]['records'][0]['source'][key]=bad
            with self.assertRaises(ValueError):contract.compare(private,C.raw,C.chapters,payload())
        for key,bad in (('book_id','900002'),('chapter_uid','22'),('source_raw_sha256','a'*64)):
            changed=payload();changed[key]=bad
            with self.assertRaises(ValueError):contract.compare(value['candidate_private'],C.raw,C.chapters,changed)

    def test_early_failure_is_unverified_and_cannot_claim_native_success(self):
        value=envelope();value['report'].update(result='UNVERIFIED',stages=[],runner_error='candidate_private')
        value['candidate_private']=[]
        self.assertEqual(contract.decode(frame(value),OWNER)['report']['runner_error'],'candidate_private')
        value['report']['result']='PASS'
        with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_partial_native_failure_requires_an_empty_array_not_an_object(self):
        row=stage();row.update(result='UNVERIFIED',phase='native')
        row['source_candidate']=dict(**dict.fromkeys(contract.FLAGS,False),**dict.fromkeys(contract.COUNTS,0))
        row['source_candidate']['preparation_failure']=4
        value=dict(report=row,cookies=COOKIES,candidate_private=dict(records=[]))
        self.assertEqual(contract.decode(frame(value),OWNER,mode='live')['report']['result'],'UNVERIFIED')
        value['candidate_private']['records']={}
        with self.assertRaises(ValueError):contract.decode(frame(value),OWNER,mode='live')

    def run_saved(self,failed=False,changed=False):
        web=MagicMock();web.vid=OWNER;web.book_id=C.point['book_id'];web.report=dict(stages=[])
        web.shards={key:'PRIVATE_SHARD' for key in ('e_0','e_1','e_3')};web.chapters=C.chapters
        web.prepare.side_effect=lambda:payload();web.baseline=dict(chapter='11',offset=15,percent=37)
        def child_reply(_command,**options):
            body=json.loads(options['input'])
            self.assertTrue(body['source_upload_preview']);self.assertNotIn('expected',body)
            self.assertNotIn('raw',body);self.assertNotIn('candidate_private',body)
            return SimpleNamespace(returncode=int(failed),stdout=b'PRIVATE_DIAGNOSTIC' if failed else frame(envelope()))
        with patch.object(task,'SessionStore') as store,patch.object(task,'Preflight',return_value=web), \
                patch.object(task,'decode_content_shards',return_value=C.raw), \
                patch.object(task,'save_refreshed_web_session',return_value=False), \
                patch.object(task,'reading_position',return_value=dict(web.baseline,offset=16) if changed else web.baseline), \
                patch.object(task.subprocess,'run',side_effect=child_reply) as child,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid=OWNER,cookies=COOKIES.copy())
            code=task.main(['--saved-session','--lua-command','synthetic-only'])
        return code,json.loads(out.getvalue()),child

    def test_saved_native_comparison_reports_no_private_text_positions_or_credentials(self):
        code,report,child=self.run_saved()
        self.assertEqual(code,0);self.assertEqual(child.call_count,1)
        self.assertEqual(report['candidates_compared'],6);self.assertTrue(report['fresh_offline_process'])
        self.assertEqual(report['account_data_writes_attempted'],0)
        for secret in (C.raw,COOKIES['wr_skey'],'candidate_private','OEBPS/text/chapter.xhtml'):
            self.assertNotIn(secret,json.dumps(report))

    def test_lost_private_frame_or_changed_cloud_position_never_reports_success_or_retries(self):
        for options in (dict(failed=True),dict(changed=True)):
            code,report,child=self.run_saved(**options)
            self.assertEqual(code,1);self.assertEqual(child.call_count,1)
            self.assertEqual(report['result'],'UNVERIFIED');self.assertNotIn('PRIVATE_DIAGNOSTIC',json.dumps(report))


if __name__=='__main__':unittest.main()
