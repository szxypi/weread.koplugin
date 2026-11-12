"""Missing-chapter selection, strict native evidence and read-only boundaries."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch
import verify_note_download as task
from run_my_mark_navigation_ui import FLAGS,COUNTS,DOWNLOAD_FLAGS,DOWNLOAD_COUNTS,public_report,validate


def stage(mode='live'):
    value=dict.fromkeys(FLAGS,True);value.update(dict.fromkeys(COUNTS,0));value.update(dict.fromkeys(DOWNLOAD_FLAGS,True));value.update(dict.fromkeys(DOWNLOAD_COUNTS,0))
    value.update(result='PASS',phase='complete',mode=mode,located=3,buttons=3,source_files=1)
    if mode=='live':value.update(requests=8,http_gets=3,catalog_posts=1,content_posts=4,confirmations=1,downloaded_chapters=1)
    else:value.update(missing_cache=False,download_confirmed=False,cancel_zero_requests=False)
    return value


def result():return dict(result='PASS',profile_removed=True,installed_bytes_match=True,installed_files=227,stages=[stage(),stage('reopen')])


class NoteDownloadTests(unittest.TestCase):
    def test_offline_default_never_loads_credentials_or_starts_a_process(self):
        with patch.object(task,'SessionStore') as web,patch.object(task,'NativeSessionStore') as native,patch.object(task,'TargetThoughtsProbe') as notes,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        for dependency in [web,native,notes,child]:dependency.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_native_command_requires_saved_session(self):
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(['--native-ui-command','forbidden'])

    def test_selection_is_one_chapter_max_three_real_references_without_mutation(self):
        rows=[dict(reviewId=f'synthetic-{i}',type=1,chapterUid=2 if i<5 else 3,abstract='引用文字',range='12-24') for i in range(7)]
        model=dict(reviews=rows+[dict(reviewId='no-range',type=1,chapterUid=1,abstract='no range')]);original=deepcopy(model)
        uid,selected=task.selection(model,'thoughts');self.assertEqual(uid,'2');self.assertEqual(selected,rows[:3]);self.assertEqual(model,original)
        marks=dict(updated=[dict(bookmarkId=row['reviewId'],type=1,chapterUid=row['chapterUid'],markText=row['abstract'],range=row['range']) for row in rows])
        self.assertEqual(task.selection(marks,'highlights')[0],'2')

    def test_selection_rejects_noncanonical_types_missing_ranges_and_other_text(self):
        for row in [dict(type=True,chapterUid=2,abstract='quote',range='12-24'),dict(type=1,chapterUid='2',abstract='quote',range='12-24'),
                    dict(type=1,chapterUid=2,content='fallback',range='12-24'),dict(type=1,chapterUid=2,abstract='quote',range='12-2')]:
            with self.assertRaises(ValueError):task.selection(dict(reviews=[row]),'thoughts')

    def test_success_requires_both_real_native_stages_and_exact_schema(self):
        self.assertEqual(task.validate_ui(result(),3)['result'],'PASS')
        for mode in ['empty','single','extra_private','unremoved','false_install','bool_files']:
            value=result()
            if mode=='empty':value['stages']=[]
            elif mode=='single':value['stages']=value['stages'][:1]
            elif mode=='extra_private':value['private']='forbidden'
            elif mode=='unremoved':value['profile_removed']=False
            elif mode=='false_install':value['installed_bytes_match']=False
            else:value['installed_files']=True
            with self.subTest(mode=mode),self.assertRaises(ValueError):task.validate_ui(value,3)

    def test_live_requires_confirmation_no_forbidden_calls_and_complete_download(self):
        for field,value in [('download_confirmed',False),('cancel_zero_requests',False),('missing_cache',False),('no_data_posts',False),
                            ('downloaded_source_verified',False),('confirmations',0),('downloaded_chapters',0),('forbidden_requests',1),
                            ('http_failures',1),('catalog_posts',2),('http_gets',30),('requests',7),('source_files',2),('requests',True)]:
            value_stage=stage();value_stage[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):validate(value_stage,'live',3,1,download=True)

    def test_offline_must_make_zero_requests_and_cannot_inherit_live_flags(self):
        for field,value in [('requests',1),('confirmations',1),('downloaded_chapters',1),('missing_cache',True),('download_confirmed',True)]:
            value_stage=stage('reopen');value_stage[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):validate(value_stage,'reopen',3,1,download=True)
        for mode,count,chapters in [('other',3,1),('live',True,1),('live',3,0)]:
            with self.assertRaises(ValueError):validate(stage(mode),mode,count,chapters,download=True)

    def test_public_report_discards_credentials_and_private_fields(self):
        value=result();value['cookies']=dict(wr_skey='private-value');value['stages'][0]['book_id']='private-book'
        sanitized=json.dumps(public_report(value));self.assertNotIn('private-value',sanitized);self.assertNotIn('private-book',sanitized)

    def test_failures_are_redacted_and_do_not_fall_back_to_login(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'TargetThoughtsProbe') as notes,redirect_stdout(io.StringIO()) as output:
            store.return_value.load.side_effect=RuntimeError('private value')
            self.assertEqual(task.main(['--saved-session']),1)
        notes.assert_not_called();self.assertNotIn('private value',output.getvalue())
        self.assertEqual(json.loads(output.getvalue())['reason'],'note_download/unverified')


if __name__=='__main__':unittest.main()
