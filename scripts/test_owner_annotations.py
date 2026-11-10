"""Offline privacy and acceptance boundaries for real chapter annotations."""
from contextlib import redirect_stdout, redirect_stderr
import copy
import io
import json
import unittest
from unittest.mock import MagicMock, patch
from types import SimpleNamespace

import owner_annotation_contract as contract
import verify_owner_annotations as task
from test_owner_reading import OWNER, envelope, frame, stage


def addon(mode='live'):
    return dict(**dict.fromkeys(contract.FLAGS, True), underlines=2, thought_items=3,
                located=2, unmatched=0, partial=0, native_underlines_requests=int(mode=='live'),
                native_thought_requests=int(mode=='live'), native_denied_requests=0, failed_line=0,
                unmatched_missing_quote=0,unmatched_quote_search_hits=0,
                unmatched_original_quote_differs=0,unmatched_original_search_hits=0,
                source_quote_recheck_located=2,source_quote_recheck_unmatched=0,
                source_quote_miss_overlap=0,source_quote_miss_equal_start=0,
                source_quote_miss_earlier_hit=0,source_quote_miss_outside_chapter=0,sealed_chapter_recheck_located=2)


class OwnerAnnotationsTests(unittest.TestCase):
    def test_default_has_no_keychain_or_network_or_child(self):
        with patch.object(task, 'SessionStore') as store, patch.object(task, 'ReadingPreflight') as web, \
                patch.object(task.subprocess, 'run') as child, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]), 0)
        store.assert_not_called(); web.assert_not_called(); child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_online_requires_explicit_saved_session_and_command(self):
        for args in (['--saved-session'], ['--lua-command', 'synthetic']):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): task.main(args)

    def test_strict_types_fields_flags_and_request_limits(self):
        for key in contract.FLAGS:
            value=addon(); value[key]=False
            with self.assertRaises(ValueError): contract.validate(value, 'live', True)
        for key, item in (('private_text','secret'),('located',True),('underlines',0),('native_thought_requests',2),
                          ('native_denied_requests',1),('failed_line',12),('unmatched',1)):
            value=addon(); value[key]=item
            with self.assertRaises(ValueError): contract.validate(value, 'live', True)

    def test_fresh_offline_process_cannot_make_native_requests(self):
        for key in ('native_underlines_requests','native_thought_requests'):
            value=addon('reopen'); value[key]=1
            with self.assertRaises(ValueError): contract.validate(value, 'reopen', True)

    def test_decode_preserves_existing_reading_contract(self):
        value=envelope()
        for mode, row in zip(('live','reopen'), value['report']['stages']): row['annotations']=addon(mode)
        self.assertEqual(contract.decode(frame(value), OWNER)['report']['result'], 'PASS')
        for key in ('plugin_selection','source_text_visible','workers_reaped'):
            bad=copy.deepcopy(value); bad['report']['stages'][0][key]=False
            with self.assertRaises(ValueError): contract.decode(frame(bad), OWNER)
        bad=copy.deepcopy(value); bad['report']['stages'][1]['annotations']['thought_items']+=1
        with self.assertRaises(ValueError): contract.decode(frame(bad), OWNER)

    def test_stage_decoder_and_private_frame_boundaries(self):
        row=stage(); row['annotations']=addon()
        self.assertEqual(contract.decode(frame(dict(report=row,cookies=envelope()['cookies'])),OWNER,mode='live')['report']['annotations'],addon())
        for raw in (b'private output',frame(envelope())*2,frame(envelope())+b'private'):
            with self.assertRaises((ValueError,KeyError)):contract.decode(raw,OWNER)
        with self.assertRaises(ValueError):contract.decode(frame(envelope()),OWNER,full_chapters=2)

    def test_digest_excludes_mutable_metrics_and_binds_every_private_text(self):
        underlines=[dict(range='10-20',score=.3,markText='generated quote')]
        reviews=[dict(range='10-20',pageReviews=[dict(review=dict(reviewId='synthetic-id',content='正文😀',abstract='引文'))])]
        original=contract.digest(underlines,reviews)
        underlines[0].update(score=.9,markText='another generated quote')
        reviews[0]['pageReviews'][0]['likesCount']=9
        self.assertEqual(contract.digest(underlines,reviews),original)
        for field in ('reviewId','content','abstract','contextAbstract'):
            changed=copy.deepcopy(reviews);changed[0]['pageReviews'][0]['review'][field]='changed'
            self.assertNotEqual(contract.digest(underlines,changed),original)
        with self.assertRaises(ValueError):contract.digest(underlines,[dict(range='10-20',pageReviews=[dict(review=dict(content=True))])])

    def test_prepare_binds_every_range_and_rejects_unread_pages(self):
        from verify_native_annotations import AnnotationProbe
        rows=[dict(range=f'{index}-{index+1}') for index in range(31)]
        pages=[dict(range=row['range'],hasMore=0,totalCount=1,pageReviews=[dict(review=dict(content='private thought'))]) for row in rows]
        payload=dict(book_id='900001',chapter_uid='2',shelf_books=1)
        credentials=dict(vid=OWNER,accessToken='synthetic-only')
        with patch.object(AnnotationProbe,'request',side_effect=[dict(underlines=rows),dict(reviews=pages[:30]),dict(reviews=pages[30:])]) as request, \
                patch.object(contract.time,'sleep') as pause:
            result=contract.prepare(payload,credentials,'x'*100)
        self.assertEqual((result['underlines'],result['thought_items'],request.call_count,pause.call_count),(31,31,3,2))
        self.assertEqual(result['ranges'],[row['range'] for row in rows])
        self.assertIs(result['credentials'],credentials)
        pages[0]['hasMore']=1
        with patch.object(AnnotationProbe,'request',side_effect=[dict(underlines=rows),dict(reviews=pages[:30]),dict(reviews=pages[30:])]), \
                patch.object(contract.time,'sleep'),self.assertRaises(ValueError):contract.prepare(payload,credentials,'x'*100)

    def test_prepare_never_uses_an_empty_current_chapter_as_success(self):
        from verify_native_annotations import AnnotationProbe
        with patch.object(AnnotationProbe,'request',return_value=dict(underlines=[])) as request,self.assertRaises(ValueError):
            contract.prepare(dict(book_id='900001',chapter_uid='2',shelf_books=1),{},'x'*100)
        self.assertEqual(request.call_count,1)

    def run_online(self, *, unmatched=0, moved=False, failure=False):
        web=MagicMock();web.vid=OWNER;web.book_id='900001';web.report=dict(stages=[])
        web.prepare.return_value=dict(book_id='900001',chapter_uid='2',shelf_books=1)
        web.baseline=dict(chapter='2',offset=10,percent=20)
        private=dict(report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,runner_error='none',stages=[]),cookies=envelope()['cookies'])
        for mode in ('live','reopen'):
            row=stage(mode);row['annotations']=addon(mode);row['annotations'].update(located=2-unmatched,unmatched=unmatched)
            private['report']['stages'].append(row)
        with patch.object(task,'SessionStore') as store,patch.object(task,'NativeSessionStore') as native, \
                patch.object(task,'ReadingPreflight',return_value=web),patch.object(task,'save_refreshed_web_session',return_value=False), \
                patch.object(task,'prepare',return_value=dict(underlines=2,thought_items=3)),patch.object(task,'decode_content_shards',return_value='<p>text</p>'), \
                patch.object(task,'reading_position',return_value=dict(chapter='2',offset=11 if moved else 10,percent=20)), \
                patch.object(task.subprocess,'run',return_value=SimpleNamespace(stdout=frame(private),returncode=0)) as child, \
                redirect_stdout(io.StringIO()) as output:
            store.return_value.load.return_value=dict(vid=OWNER,cookies=envelope()['cookies'])
            native.return_value.load.return_value=dict(vid=OWNER,accessToken='synthetic-private-token')
            if failure:child.side_effect=RuntimeError('synthetic-private-token')
            code=task.main(['--saved-session','--lua-command','synthetic'])
        return code,json.loads(output.getvalue())

    def test_online_complete_and_partial_results_stay_distinct(self):
        code,result=self.run_online()
        self.assertEqual(code,0);self.assertTrue(result['complete_matching_verified'])
        code,result=self.run_online(unmatched=1)
        self.assertEqual(code,1);self.assertEqual(result['result'],'OWNER_NATIVE_ANNOTATIONS_PARTIAL')
        self.assertFalse(result['complete_matching_verified']);self.assertTrue(result['cloud_position_unchanged'])

    def test_changed_cloud_position_and_private_failures_do_not_pass(self):
        for option in (dict(moved=True),dict(failure=True)):
            code,result=self.run_online(**option)
            self.assertEqual(code,1);self.assertEqual(result['result'],'UNVERIFIED')
            self.assertNotIn('synthetic-private-token',json.dumps(result))


if __name__ == '__main__':
    unittest.main()
