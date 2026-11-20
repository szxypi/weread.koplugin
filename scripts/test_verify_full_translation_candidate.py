import contextlib
import copy
import io
import json
import unittest
from unittest.mock import patch

from verify_full_translation_candidate import eligible, main, shelf_english_ids


def sample(count=3):
    rows = [dict(chapterUid=i, wordCount=300, title='Synthetic') for i in range(1, count+1)]
    projected = [dict(uid=i, wordCount=300, free_or_owned=True) for i in range(1, count+1)]
    return dict(expected=dict(book_id='900001', format='epub', chapters=projected),
                source=dict(data=[dict(bookId='900001', updated=rows)]))


class FullTranslationCandidateTests(unittest.TestCase):
    def test_all_readable_chapters_must_be_explicitly_accessible(self):
        value = sample()
        self.assertEqual(len(eligible(value)), 3)
        for field, replacement in (('free_or_owned', False), ('free_or_owned', None), ('uid', 0)):
            modified = copy.deepcopy(value); modified['expected']['chapters'][1][field] = replacement
            with self.subTest(field=field,replacement=replacement): self.assertIsNone(eligible(modified))

    def test_cover_is_excluded_but_other_readable_chapters_are_not(self):
        value = sample(4)
        value['source']['data'][0]['updated'][0]['title'] = '封面'
        value['expected']['chapters'][0]['free_or_owned'] = False
        self.assertEqual(len(eligible(value)), 3)
        value['source']['data'][0]['updated'][0]['title'] = 'Copyright'
        self.assertIsNone(eligible(value))

    def test_identity_shape_format_and_work_limits_are_strict(self):
        for modified in (sample(1), sample(65), dict(sample(),source={}),
                         dict(sample(),expected=dict(sample()['expected'],format=None))):
            self.assertIsNone(eligible(modified))
        value=sample();value['source']['data'][0]['updated'][1]['chapterUid']=99
        self.assertIsNone(eligible(value))
        value=sample();value['source']['data'][0]['updated'][1]['wordCount']=float('nan')
        self.assertIsNone(eligible(value))

    def test_default_never_opens_saved_sessions(self):
        with patch('verify_full_translation_candidate.SessionStore', side_effect=AssertionError('opened')):
            with contextlib.redirect_stdout(io.StringIO()) as output:self.assertEqual(main([]),0)
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_single_query_selection_is_validated_offline(self):
        with patch('verify_full_translation_candidate.SessionStore', side_effect=AssertionError('opened')):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(main(['--query','The Metamorphosis']),0)
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main(['--query','unapproved query'])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main(['--shelf','--query','The Metamorphosis'])

    def test_shelf_selection_is_bounded_numeric_and_identity_checked(self):
        rows=[dict(bookId=str(i+1),title='A Synthetic English Book') for i in range(35)]
        rows += [dict(bookId='CB_synthetic',title='A Synthetic English Book'),
                 dict(bookId='70',title='中文书名'),
                 dict(bookId='71',title='A Synthetic English Book',bookInfo=dict(bookId='72'))]
        found,truncated=shelf_english_ids({'books':rows})
        self.assertEqual(len(found),30)
        self.assertTrue(truncated)
        self.assertNotIn('CB_synthetic',found)
        self.assertNotIn('71',found)
        self.assertEqual(shelf_english_ids({'books':rows[-3:]}),([],False))
        with self.assertRaises(ValueError):shelf_english_ids({'books':'invalid'})

    def test_live_reports_only_bounded_nonprivate_fields(self):
        saved=dict(vid='1',cookies={'wr_vid':'1'}); grant=dict(vid='1',accessToken='private')
        queries=[]
        class Session:
            def load(self): return copy.deepcopy(saved)
        class Store:
            def load(self,_owner): return copy.deepcopy(grant)
        class Probe:
            def __init__(self,**kwargs):
                self.samples=[]
                if 'public_query' in kwargs: queries.append(kwargs['public_query'])
            def request(self,*_args,**_kwargs): return {'synthetic':'private'}
            def inspect(self,*_args,**_kwargs): self.samples=[sample()]
        class Web:
            def __init__(self): self.vid=None
            def set_cookie(self,*_args): pass
            def verify_account(self): pass
            def inspect_content(self,*_args): return {'nonempty_translation_blocks':1}
            def close(self): pass
        with patch('verify_full_translation_candidate.SessionStore',Session),patch('verify_full_translation_candidate.NativeSessionStore',Store),\
             patch('verify_full_translation_candidate.Native',Probe),patch('verify_full_translation_candidate.Web',Web),\
             patch('verify_full_translation_candidate.state_hash',return_value='private_hash'),\
             patch('verify_full_translation_candidate.save_refreshed_web_session'):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(main(['--saved-session','--query','The Happy Prince']),0)
        result=json.loads(output.getvalue())
        self.assertEqual(result['result'],'FULL_TRANSLATION_DISCOVERY_CHECKED')
        self.assertEqual(queries,['The Happy Prince'])
        self.assertEqual(result['public_queries'],1)
        self.assertTrue(result['translated_chapter_confirmed'])
        self.assertNotIn('900001',output.getvalue())
        self.assertNotIn('private_hash',output.getvalue())


if __name__=='__main__': unittest.main()
