"""Synthetic native metadata checks; no owner account, Keychain or network."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from verify_book_metadata import MetadataError
from verify_native_metadata import NativeMetadataProbe,main,normalize_native


class NativeMetadataTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch('verify_native_metadata.SessionStore') as web,patch('verify_native_metadata.NativeSessionStore') as native,\
                patch('verify_native_metadata.NativeMetadataProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        web.assert_not_called();native.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_total_words_display_mapping_excludes_reader_state(self):
        source=dict(bookId='900001',title='Synthetic',totalWords=12345,version=700,bookVersion=900,
                    chapterOffset=23,progress=80,finishReading=1,token='private')
        self.assertEqual(normalize_native(source,'900001'),dict(bookId='900001',title='Synthetic',wordCount=12345))
        self.assertNotIn('wordCount',source)
        self.assertEqual(normalize_native(dict(source,wordCount=17),'900001')['wordCount'],17)
        for invalid in (-1,float('nan'),float('inf'),'12345',False):
            self.assertNotIn('wordCount',normalize_native(dict(source,totalWords=invalid),'900001'))

    def test_guard_only_allows_selected_gets(self):
        probe=NativeMetadataProbe();probe.allowed_ids={'900001'}
        probe.guard('metadata_shelf','https://i.weread.qq.com/shelf/sync',None)
        probe.guard('metadata','https://i.weread.qq.com/book/info?bookId=900001',None)
        for stage,url,body in (
            ('metadata','https://i.weread.qq.com/book/info?bookId=900002',None),
            ('metadata','https://i.weread.qq.com/book/info?bookId=900001&bookId=900001',None),
            ('metadata','https://i.weread.qq.com/book/info?bookId=900001&extra=',None),
            ('metadata','https://evil.invalid/book/info?bookId=900001',None),
            ('metadata','http://i.weread.qq.com/book/info?bookId=900001',None),
            ('metadata','https://i.weread.qq.com/book/info?bookId=900001#hidden',None),
            ('metadata','https://i.weread.qq.com/book/info?bookId=900001',{}),
            ('write','https://i.weread.qq.com/shelf/add?bookId=900001',None)):
            with self.subTest(url=url),self.assertRaises(MetadataError):probe.guard(stage,url,body)

    def test_inspection_is_bounded_and_report_has_no_values(self):
        probe=NativeMetadataProbe()
        with patch.object(probe,'request',side_effect=[dict(books=[dict(bookId='900001'),dict(bookId='900002')]),
                dict(bookId='900001',title='private-title',totalWords=99)]) as request:
            result=probe.inspect({},1)
        self.assertEqual(result['sampled_book_count'],1)
        self.assertEqual(request.call_count,2)
        self.assertEqual(probe.allowed_ids,{'900001'})
        self.assertNotIn('private-title',json.dumps(result));self.assertNotIn('900001',json.dumps(result))
        with self.assertRaises(MetadataError):probe.inspect({},5)

    def test_child_failure_is_redacted_and_credentials_retained_in_store(self):
        credentials=dict(vid='88008800',accessToken='private-access')
        sample=dict(book_id='99009900',source=dict(bookId='99009900',title='private-title'),expected=dict(bookId='99009900',title='private-title'),native=True)
        probe=SimpleNamespace(inspect=lambda *_:dict(sampled_book_count=1),samples=[sample],report=dict(stages=[]))
        with patch('verify_native_metadata.SessionStore') as web,patch('verify_native_metadata.NativeSessionStore') as native,\
                patch('verify_native_metadata.NativeMetadataProbe',return_value=probe),\
                patch('verify_native_metadata.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout=b'private-output')) as child,\
                redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='88008800')
            native.return_value.load.return_value=credentials
            self.assertEqual(main(['--saved-session','--native-http','--lua-command','synthetic']),1)
        native.return_value.delete.assert_not_called()
        self.assertIn('private-access',child.call_args.kwargs['input'].decode())
        self.assertEqual(credentials,{})
        for private in ('private-access','private-title','private-output','88008800','99009900'):self.assertNotIn(private,out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['reason'],'lua_probe_failed')


if __name__=='__main__':unittest.main()
