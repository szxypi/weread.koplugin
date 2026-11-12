"""No-chapter UI proof is read-only, scoped and honest about initialization."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import hashlib,io,json,unittest
from unittest.mock import patch
from owner_unstarted_contract import FLAGS,FRAME,validate_payload,decode,decode_runner,compare
from test_owner_reading import stage as reading_stage
from test_owner_cloud_source import payload as cloud_payload
from verify_source_remote_position import compare as compare_models,FRAME as MODEL_FRAME
import verify_source_remote_position as model_task
import verify_owner_unstarted as task

RAW='Synthetic source for an unstarted reader validation. '*8


def payload():
    v=cloud_payload();v.pop('raw_cloud_preview');v['unstarted_preview']=True;v['unstarted_mock_port']=v.pop('cloud_mock_port')
    v['source_raw_sha256']=hashlib.sha256(RAW.encode()).hexdigest();return v


def private():
    v=payload();p=dict(book_id=v['book_id'],chapter_uid=v['chapter_uid'],chapter_offset=0,file_id='a'*64,book_version=7,
                     raw_sha256=v['source_raw_sha256'],render_path='OEBPS/text/chapter.xhtml',basis='raw_txt_utf16',upload_verified=False)
    return dict(position=deepcopy(p),checkpoint=deepcopy(p))


def stage(mode='live'):
    r=reading_stage(mode);a={k:False for k in FLAGS}
    keys={'parent_native_guard','local_intent','unverified','timer_stopped'}|({'offline_local_only','initial_offline_checkpoint'} if mode=='reopen' else {'no_chapter_notice','no_choice','retry_kept'})
    for k in keys:a[k]=True
    a.update(native_denied=0,failed_line=0);r['unstarted']=a;return r


def envelope(mode='live'):return dict(report=stage(mode),cookies=dict(wr_vid='900000',wr_skey='mock_key'),candidate_private=private())
def frame(v):return FRAME+json.dumps(v).encode()


class UnstartedTests(unittest.TestCase):
    def test_default_never_loads_credentials_or_network_or_reader(self):
        for module in (task,model_task):
            with patch.object(module,'SessionStore') as session,patch.object(module,'NativeSessionStore') as grant,patch.object(module.subprocess,'run') as child,redirect_stdout(io.StringIO()) as output:
                self.assertEqual(module.main([]),0)
            session.assert_not_called();grant.assert_not_called();child.assert_not_called()
            self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
    def test_incomplete_cli_is_rejected(self):
        for module,args in ((task,['--saved-session']),(task,['--lua-command','synthetic']),
                            (model_task,['--lua-command','synthetic']),(model_task,['--sample','17'])):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):module.main(args)
    def test_no_grants_write_slots_or_summaries_are_accepted(self):
        validate_payload(payload(),12345)
        for k in ('native_grant','permit_writes','native_timer_trial','summary','raw_cloud_preview'):
            v=payload();v[k]={}
            with self.assertRaises(ValueError):validate_payload(v,12345)
    def test_mock_scope_and_closed_input(self):
        for changes in ({'vid':'900009'},{'unstarted_preview':False},{'source_format':'web_xhtml'},{'source_sample_offset':True}):
            v=payload();v.update(changes)
            with self.assertRaises(ValueError):validate_payload(v,12345)
    def test_all_live_and_offline_flags_are_required(self):
        for mode in ('live','reopen'):
            v=envelope(mode);decode(frame(v),'900000',mode)
            for k in FLAGS:
                bad=deepcopy(v);bad['report']['unstarted'][k]=not bad['report']['unstarted'][k]
                with self.subTest(k=k,mode=mode),self.assertRaises(ValueError):decode(frame(bad),'900000',mode)
    def test_native_attempt_or_hidden_private_report_is_rejected(self):
        for k,v in (('native_denied',1),('summary','private'),('failed_line',3)):
            bad=envelope();bad['report']['unstarted'][k]=v
            with self.assertRaises(ValueError):decode(frame(bad),'900000','live')
    def test_independent_local_checkpoints_must_survive_offline_unchanged(self):
        records=[private(),private()];compare(records,payload(),RAW)
        for modify in (lambda r:r[1]['checkpoint'].update(chapter_offset=1),lambda r:r[0]['position'].update(raw_sha256='f'*64),
                       lambda r:r[0]['checkpoint'].update(upload_verified=True)):
            v=deepcopy(records);modify(v)
            with self.assertRaises(ValueError):compare(v,payload(),RAW)
    def test_profile_cleanup_and_installed_bytes_are_required(self):
        v=dict(report=dict(result='PASS',profile_removed=True,stages=[stage(),stage('reopen')],installed=dict(files=286,bytes_match=True),error='none'),
               cookies=dict(wr_vid='900000',wr_skey='mock_key'),candidate_private=[private(),private()])
        decode_runner(frame(v),'900000')
        for key,value in (('profile_removed',False),('installed',dict(files=286,bytes_match=False))):
            bad=deepcopy(v);bad['report'][key]=value
            with self.assertRaises(ValueError):decode_runner(frame(bad),'900000')
    def test_python_lua_comparison_preserves_missing_index_provenance(self):
        sample=dict(raw=dict(progress=10,chapterUid=22,chapterOffset=0),book_id='900001',chapters=[dict(chapterUid=22,chapterIdx=7)],source='web')
        from source_remote_position import outcome
        v=[outcome(sample['raw'],sample['book_id'],sample['chapters'])]
        compare_models(MODEL_FRAME+json.dumps(v).encode(),[sample])
        v[0]['position']['chapter_idx']=0
        with self.assertRaises(ValueError):compare_models(MODEL_FRAME+json.dumps(v).encode(),[sample])
    def test_initial_read_uses_real_first_chapter_without_claiming_a_cloud_position(self):
        source=task.Source();source.book_id='900001';source.authenticated=True
        source.request=lambda *_a,**_k:dict(progress=0,chapterUid=0,chapterOffset=0)
        self.assertEqual(source.choose_chapter([dict(chapterUid=22,chapterIdx=7,wordCount=500)])['chapterUid'],'22')
        with self.assertRaises(task.SkipBook):source.choose_chapter([dict(chapterUid=22,wordCount=5)])
        source.request=lambda *_a,**_k:dict(progress=10,chapterUid=22,chapterOffset=100)
        with self.assertRaises(task.SkipBook):source.choose_chapter([dict(chapterUid=22,chapterIdx=7,wordCount=500)])
    def test_private_failures_are_not_printed(self):
        with patch('verify_native_thought_trial.other_pending',return_value=False),patch.object(task,'SessionStore',side_effect=ValueError('PRIVATE_COOKIE')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main(['--saved-session','--lua-command','synthetic']),1)
        self.assertNotIn('PRIVATE_COOKIE',out.getvalue());self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)


if __name__=='__main__':unittest.main()
