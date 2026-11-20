"""Offline coordinate confirmation contracts; no real credentials or writes."""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
import unittest
from unittest.mock import patch, MagicMock
from types import SimpleNamespace

import verify_progress_readback as task

POINT = dict(book_id='900001', chapter_uid=2, chapter_idx=1, chapter_offset=0, percent=25.9)
RAW = dict(bookId='900001', chapterUid='2', chapterIdx=1, chapterOffset=0, progress=25.9)


class ReadbackTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as store, patch.object(task.subprocess,'run') as child, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called(); child.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_lua_command_needs_saved_session(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): task.main(['--lua-command','synthetic'])

    def test_exact_coordinate_and_zero_fields(self):
        target=task.expected('900001',POINT)
        self.assertEqual(target['percent'],25)
        self.assertTrue(task.check(RAW,target)['matches'])
        for field in ('chapter_idx','chapter_offset','chapter_uid'):
            changed=dict(target);changed[field]=3
            self.assertFalse(task.check(RAW,changed)['matches'])

    def test_server_percent_is_independent_metadata(self):
        self.assertTrue(task.check(dict(RAW,progress=26.7),task.expected('900001',POINT))['matches'])

    def test_absent_coordinate_is_never_defaulted_to_zero(self):
        for field in ('chapterUid','chapterIdx','chapterOffset'):
            raw=dict(RAW);del raw[field]
            self.assertFalse(task.check(raw,task.expected('900001',POINT))['matches'])

    def test_invalid_foreign_ambiguous_and_conflicting_aliases(self):
        for raw in (dict(RAW,bookId='900002'),dict(RAW,chapterOffset='bad'),dict(RAW,progress=101),
                    dict(RAW,chapter_uid=3),dict(RAW,succ=0),dict(data=[RAW,RAW])):
            self.assertFalse(task.check(raw,task.expected('900001',POINT))['matches'])

    def test_invalid_target_is_rejected_before_dispatch(self):
        for patching in (dict(book_id='900002'),dict(basis='filtered_xhtml_utf16'),dict(upload_verified=False),
                         dict(chapter_uid=None),dict(chapter_idx=None),dict(chapter_offset=-1),dict(percent=float('nan'))):
            with self.assertRaises(ValueError): task.expected('900001',dict(POINT,**patching))
        nested=dict(POINT,source_position=dict(basis='filtered_xhtml_utf16',upload_verified=False))
        self.assertEqual(task.expected('900001',nested),task.expected('900001',POINT))

    def test_saved_session_compares_private_model_and_prints_only_fixed_counts(self):
        web=MagicMock();web.report=dict(stages=[])
        samples=[dict(raw=RAW,target=task.expected('900001',POINT))]
        for field in ('chapter_idx','chapter_offset'):
            target=dict(samples[0]['target']);target[field]+=1
            samples.append(dict(raw=RAW,target=target))
        web.request.side_effect=[dict(books=[dict(bookId='900001')]),RAW]
        output=task.FRAME+json.dumps([task.check(s['raw'],s['target']) for s in samples]).encode()
        with patch.object(task,'SessionStore') as store,patch.object(task,'WebSourceProbe',return_value=web), \
                patch.object(task,'save_refreshed_web_session',return_value=False),patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid='900001',cookies={})
            child.return_value=SimpleNamespace(returncode=0,stdout=output)
            self.assertEqual(task.main(['--saved-session','--lua-command','synthetic']),0)
        result=json.loads(out.getvalue())
        self.assertEqual((result['positions'],result['comparisons']),(1,3))
        self.assertTrue(result['lua_comparison_matches'])
        self.assertEqual(result['account_data_writes_attempted'],0)
        self.assertNotIn('900001',out.getvalue())
        self.assertEqual(web.request.call_args_list[1].args[0],'selection_progress')


if __name__=='__main__':unittest.main()
