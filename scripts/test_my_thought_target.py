"""Quoted-thought source targets: no writes, network or account access."""
from copy import deepcopy
from contextlib import redirect_stdout,redirect_stderr
import io
import json
import unittest
from unittest.mock import patch
from my_thought_target import project,reference
from my_mark_target import project as mark_target
import verify_my_thought_target as task
from my_cloud_thoughts_model import complete
from test_eink_login import Opener
from test_secure_native_session import credentials


def fixture():
    raw='<html><body><p>合成引文之前 😀。Unique quoted &amp; <b>selected text</b> 引文结束。</p></body></html>'
    start=raw.index('Unique');end=raw.index('</b>')+4
    row=dict(reviewId='synthetic-review',type=1,chapterUid=2,chapterIdx=1,range=f'{start}-{end}',abstract='Unique quoted & selected text',content='My separate thought',isPrivate=1)
    return raw,row


class ThoughtTargetTests(unittest.TestCase):
    def test_quote_uses_existing_independently_verified_range_conversion(self):
        raw,row=fixture();expected=mark_target(raw,'41','2',dict(type=1,chapterUid=2,range=row['range'],markText=row['abstract']))
        self.assertEqual(project(raw,'41','2',row),expected)
        self.assertFalse(expected['upload_verified']);self.assertEqual(expected['basis'],'filtered_xhtml_utf16')
        self.assertNotEqual(expected['chapter_offset'],int(row['range'].split('-')[0]))

    def test_thought_prose_and_unrelated_highlight_do_not_replace_the_quote(self):
        raw,row=fixture();row['content']='A different note';self.assertEqual(project(raw,'41','2',row)['chapter_uid'],'2')
        for mode in ['missing','empty','changed']:
            bad=deepcopy(row);bad['markText']=row['abstract'];bad['content']=row['abstract']
            if mode=='missing':bad.pop('abstract')
            elif mode=='empty':bad['abstract']=''
            else:bad['abstract']='Changed selected text'
            with self.subTest(mode=mode),self.assertRaises(ValueError):project(raw,'41','2',bad)

    def test_book_chapter_review_and_type_are_checked(self):
        raw,row=fixture()
        for key,value in [('bookId','42'),('chapterUid',3),('chapterUid','2'),('chapterUid',True),('type',0),('type',True),('reviewId',''),('reviewId','bad id'),('reviewId','bad\u3000id')]:
            bad=dict(row,**{key:value})
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):project(raw,'41','2',bad)
        for book,chapter in [('CB_fake','2'),('41','0'),('41','3')]:
            with self.assertRaises(ValueError):project(raw,book,chapter,row)

    def test_missing_malformed_or_stale_ranges_never_fall_back_to_text_search(self):
        raw,row=fixture()
        for marker in [None,'','1:2','2-1','0-999999999999','1-9999','1-2']:
            with self.subTest(marker=marker),self.assertRaises(ValueError):project(raw,'41','2',dict(row,range=marker))
        with self.assertRaises(ValueError):project(raw.replace('Unique','Modified'),'41','2',row)

    def test_privacy_and_empty_note_text_do_not_change_a_valid_source_reference(self):
        raw,row=fixture();expected=project(raw,'41','2',row)
        for privacy in [0,1,None]:
            value=dict(row,isPrivate=privacy,content='');self.assertEqual(project(raw,'41','2',value),expected)
        self.assertEqual(set(reference('41','2',row)),{'bookId','type','chapterUid','markText','range'})


class ReadOnlyTests(unittest.TestCase):
    def test_default_does_not_load_credentials_or_open_network(self):
        with patch.object(task,'SessionStore') as web,patch.object(task,'NativeSessionStore') as native,patch.object(task,'TargetThoughtsProbe') as notes,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        for dependency in [web,native,notes]:dependency.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_comparison_requires_explicit_saved_session(self):
        for option in ['--lua-command','--native-ui-command']:
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main([option,'forbidden'])

    def test_guard_blocks_writes_other_books_variants_and_unbounded_reads(self):
        opener=Opener([]);probe=task.TargetThoughtsProbe(opener);probe.identity='41'
        exact=task.NATIVE+'/review/list?bookId=41&listType=11&listMode=0&mine=1&synckey=0&count=20'
        for stage,url,body in [('thoughts_20',exact,{}),('write',task.NATIVE+'/review/delete',{}),('thoughts_20',exact.replace('bookId=41','bookId=42'),None),
                               ('thoughts_20',exact.replace('listType=11','listType=1'),None),('thoughts_20',exact.replace('count=20','count=21'),None)]:
            with self.assertRaises(ValueError):probe.request(stage,url,body,credentials())
        self.assertEqual(len(opener.requests),0);probe.calls=24
        with self.assertRaises(ValueError):probe.request('thoughts_20',exact,credentials=credentials())
        self.assertEqual(len(opener.requests),0)

    def test_full_list_rechecks_stable_prefix_even_with_false_has_more(self):
        _raw,row=fixture();a=dict(row,reviewId='synthetic-a',bookId='41',userVid=900000);b=dict(row,reviewId='synthetic-b',bookId='41',userVid=900000)
        def source(rows):return dict(totalCount=2,hasMore=0,reviews=[dict(reviewId=r['reviewId'],review=r) for r in rows])
        opener=Opener([source([a]),source([a,b])]);probe=task.TargetThoughtsProbe(opener);probe.identity='41'
        result=task.read_all(probe,credentials());self.assertEqual(result,complete(source([a,b]),'41','900000',1))
        self.assertTrue(all(request.get_method()=='GET' for request in opener.requests));self.assertEqual(len(opener.requests),2)
        changed=dict(a,content='Another device edited the prefix');opener=Opener([source([a]),source([changed,b])]);probe=task.TargetThoughtsProbe(opener);probe.identity='41'
        with self.assertRaisesRegex(ValueError,'changed'):task.read_all(probe,credentials())

    def test_credential_failure_is_redacted_and_does_not_fall_back(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'TargetThoughtsProbe') as probe,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.side_effect=RuntimeError('private credential text')
            self.assertEqual(task.main(['--saved-session']),1)
        probe.assert_not_called();self.assertNotIn('private credential text',out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['reason'],'my_thought_target/prototype_failed')


if __name__=='__main__':unittest.main()
