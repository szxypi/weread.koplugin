"""Synthetic book metadata; no credentials, Keychain or upstream requests."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from verify_book_metadata import MetadataError,from_reader,main,normalize


class MetadataTests(unittest.TestCase):
    def test_projection_excludes_positions_versions_and_sessions(self):
        source=dict(bookId='900001',title='Synthetic',intro='Paragraph\n\nParagraph',publisher='Publisher',
                    version=7,bookVersion=8,progress=83,chapterOffset=123,psvts='private',token='private')
        result=normalize(source,'900001')
        self.assertEqual(result,dict(bookId='900001',title='Synthetic',intro=source['intro'],publisher='Publisher'))

    def test_state_json_is_required_and_identity_must_match(self):
        value=dict(reader=dict(bookInfo=dict(bookId='900001',title='Nested { braces }')))
        html='<script>window.__INITIAL_STATE__='+json.dumps(value)+';(function(){})();</script>'
        self.assertEqual(from_reader(html,'900001')['title'],'Nested { braces }')
        for broken in (json.dumps(value),'<script>window.__INITIAL_STATE__=invalid;(function(){})();</script>'):
            with self.assertRaises(MetadataError):from_reader(broken,'900001')
        with self.assertRaises(MetadataError):from_reader(html,'900002')

    def test_bounds_and_finite_optional_fields(self):
        for source in ({},dict(bookId='900002',title='Wrong'),dict(bookId='900001',title='bad\nname'),dict(bookId='900001',title='中'*1366)):
            with self.assertRaises(MetadataError):normalize(source,'900001')
        result=normalize(dict(bookId='900001',title='Book',author='bad\x00text',intro='x'*65537,newRating=1001,
                              newRatingCount=-1,wordCount=float('nan'),publishTime=float('inf')),'900001')
        self.assertEqual(result,dict(bookId='900001',title='Book'))

    def test_default_does_not_open_keychain_or_network(self):
        with patch('verify_book_metadata.SessionStore') as store,patch('verify_book_metadata.WebSourceProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_saved_report_omits_private_titles_identity_and_cookie(self):
        html='<script>window.__INITIAL_STATE__='+json.dumps(dict(reader=dict(bookInfo=dict(bookId='99009900',title='private-title-sentinel'))))+';(function(){})();</script>'
        with patch('verify_book_metadata.SessionStore') as store,patch('verify_book_metadata.WebSourceProbe') as probe,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid='88008800',cookies=dict(wr_skey='private-cookie-sentinel'))
            probe.return_value.request.side_effect=[dict(books=[dict(bookId='99009900')]),html]
            probe.return_value.report=dict(stages=[dict(stage='account',status=200)])
            self.assertEqual(main(['--saved-session']),0)
        for private in ('private-title-sentinel','private-cookie-sentinel','88008800','99009900'):
            self.assertNotIn(private,out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['display_field_counts'],dict(bookId=1,title=1))

    def test_new_verified_session_survives_optional_native_failure(self):
        html='<script>window.__INITIAL_STATE__='+json.dumps(dict(reader=dict(bookInfo=dict(bookId='99009900',title='Synthetic'))))+';(function(){})();</script>'
        cookies=[SimpleNamespace(name=k,value=v,domain='.weread.qq.com',path='/') for k,v in dict(wr_vid='88008800',wr_skey='private-new-cookie').items()]
        probe=SimpleNamespace(cookies=cookies,vid=None,set_cookie=lambda *_:None,verify_account=lambda:None,
            request=lambda stage,*_,**__:dict(books=[dict(bookId='99009900')]) if stage=='shelf' else html,
            close=lambda:None,report=dict(stages=[]))
        with patch('verify_book_metadata.SessionStore') as store,patch('verify_book_metadata.WebSourceProbe',return_value=probe),\
            patch('verify_book_metadata.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout=b'private-output')) as child,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid='88008800',cookies=dict(wr_vid='88008800',wr_skey='private-old-cookie'))
            self.assertEqual(main(['--saved-session','--native-http','--lua-command','synthetic-probe']),1)
            store.return_value.save.assert_called_once_with(probe)
        self.assertEqual(child.call_args.args[0],['synthetic-probe'])
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['session']['cookies']['wr_skey'],'private-new-cookie')
        self.assertNotIn('private-',out.getvalue())
        self.assertTrue(json.loads(out.getvalue())['refreshed_session_saved_to_keychain'])


if __name__=='__main__':unittest.main()
