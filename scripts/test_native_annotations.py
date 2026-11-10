"""Native annotation contract and privacy boundaries; no live account."""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import verify_native_annotations as native

BOOK = '900001'
CHAPTER = '2'


def underline():
    return dict(range='12-45', count=3, score=0.25, type=0, metadata=None)


def thoughts():
    return dict(reviews=[dict(range='12-45', totalCount=1, hasMore=0, pageReviews=[dict(review=dict(
        bookId=BOOK, chapterUid=2, content='private thought', abstract='private source quote', range='12-45'))])])


class NativeAnnotationsTests(unittest.TestCase):
    def test_default_never_loads_credentials_or_sends_requests(self):
        with patch.object(native, 'SessionStore') as web, patch.object(native, 'NativeSessionStore') as store, \
                patch.object(native, 'AnnotationProbe') as probe, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(native.main([]), 0)
        web.assert_not_called(); store.assert_not_called(); probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')

    def test_network_comparison_requires_saved_session_and_captured_command(self):
        for args in (['--lua-command', 'synthetic'], ['--native-http'], ['--saved-session', '--native-http']):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): native.main(args)

    def test_underline_projection_keeps_needed_fields_and_null_metadata(self):
        row=underline();source=dict(bookId=BOOK, chapterUid=2, underlines=[row], synckey=17)
        result=native.project('underlines', source, BOOK, CHAPTER)
        self.assertEqual(result, dict(underlines=[row]))
        result['underlines'][0]['count']=0
        self.assertEqual(source['underlines'][0]['count'], 3)
        self.assertEqual(native.project('underlines',dict(underlines=[]),BOOK,CHAPTER),dict(underlines=[]))

    def test_every_explicit_book_or_chapter_identity_must_match(self):
        for field,value in [('bookId','900002'),('book_id','900002'),('chapterUid',3),('chapter_uid',3)]:
            for level in ('root','row','review'):
                source=thoughts()
                target=source if level=='root' else source['reviews'][0] if level=='row' else source['reviews'][0]['pageReviews'][0]['review']
                target[field]=value
                with self.subTest(field=field,level=level), self.assertRaises(native.AnnotationError):
                    native.project('thoughts',source,BOOK,CHAPTER,native.batch_for([underline()]))

    def test_invalid_arrays_counters_duplicates_and_error_responses_fail(self):
        invalid=[dict(underlines={}),dict(underlines=None),dict(underlines=[underline(),underline()]),
                 dict(underlines=[dict(underline(),score=float('nan'))]),dict(underlines=[dict(underline(),count=True)]),
                 dict(underlines=[underline()],errcode=-2041),dict(underlines=[underline()],errCode=False),
                 dict(underlines=[underline()],succ=False),dict(underlines=[underline()]*4097)]
        for source in invalid:
            with self.subTest(source_type=type(source.get('underlines'))),self.assertRaises(native.AnnotationError):
                native.project('underlines',source,BOOK,CHAPTER)

    def test_ranges_and_chapter_ids_are_bounded(self):
        for value in ('','0-0','10-1','1--2','-1-2','1-2147483648','private',None,1):
            with self.subTest(value=value),self.assertRaises(native.AnnotationError):native.range_value(value)
        for value in (0,-1,True,'02','2.0',2147483648,None):
            with self.subTest(value=value),self.assertRaises(native.AnnotationError):native.uid(value)
        self.assertEqual(native.uid(2),'2')

    def test_thought_batch_is_bounded_and_ordered(self):
        rows=[dict(range=f'{index}-{index+1}') for index in range(61)]
        batch=native.batch_for(rows)
        self.assertEqual(len(batch),30)
        self.assertEqual(batch[0],dict(range='0-1',maxIdx=0,count=30,synckey=0))
        self.assertEqual(batch[-1]['range'],'29-30')
        self.assertEqual(len(native.validate_batch(batch)),30)
        for invalid in ([],{},batch+[batch[0]],[dict(batch[0],maxIdx=False)],[dict(batch[0],extra=0)],[batch[0],batch[0]]):
            with self.subTest(value_type=type(invalid)),self.assertRaises(native.AnnotationError):native.validate_batch(invalid)

    def test_thoughts_are_bound_to_requested_ranges_and_keep_full_content(self):
        source=thoughts();batch=native.batch_for([underline()])
        self.assertEqual(native.project('thoughts',source,BOOK,CHAPTER,batch),source)
        for mutate in (lambda value:value['reviews'][0].update(range='1-2'),
                       lambda value:value['reviews'][0].update(pageReviews={}),
                       lambda value:value['reviews'][0]['pageReviews'][0]['review'].update(content='x'*65537)):
            source=thoughts();mutate(source)
            with self.assertRaises(native.AnnotationError):native.project('thoughts',source,BOOK,CHAPTER,batch)

    def test_guard_permits_only_exact_read_contracts_for_current_target(self):
        probe=native.AnnotationProbe();probe.book_id=BOOK;probe.chapter_uid=CHAPTER;probe.batch=native.batch_for([underline()])
        body=dict(bookId=BOOK,chapterUid=2,cht2sMode='',reviews=probe.batch)
        probe.guard('shelf',native.BASE+'/shelf/sync',None)
        probe.guard('catalog',native.BASE+'/book/chapterInfos',native.catalog_body(BOOK))
        probe.guard('underlines',native.BASE+'/book/underlines?bookId=900001&chapterUid=2&synckey=0',None)
        probe.guard('thoughts',native.BASE+'/book/readreviews',body)
        for stage,url,data in [('login',native.BASE+'/login',{}),('write',native.BASE+'/book/addBookmark',body),
                               ('thoughts',native.BASE+'/book/readreviews',dict(body,bookId='900002')),
                               ('thoughts',native.BASE+'/book/readreviews',dict(body,extra=0)),
                               ('thoughts',native.BASE+'/book/readreviews?extra=0',body),
                               ('underlines',native.BASE+'/book/underlines?bookId=900001&chapterUid=2&synckey=0&bookId=900001',None),
                               ('underlines','https://evil.invalid/book/underlines?bookId=900001&chapterUid=2&synckey=0',None)]:
            with self.subTest(stage=stage,url=url),self.assertRaises(native.AnnotationError):probe.guard(stage,url,data)

    def test_inspect_stops_after_one_nonempty_thought_batch(self):
        probe=native.AnnotationProbe()
        catalog=dict(data=[dict(bookId=BOOK,book=dict(bookId=BOOK,format='epub'),updated=[
            dict(chapterUid=0,wordCount=1),dict(chapterUid=2,wordCount=500),dict(chapterUid=3,wordCount=700)])])
        with patch.object(probe,'request',side_effect=[dict(books=[dict(bookId=BOOK)]),dict(bookId=BOOK),catalog,
                                                     dict(underlines=[underline()]),thoughts()]) as request:
            # The longest chapter is selected; bind the synthetic reply to it.
            catalog['data'][0]['updated'][2]['wordCount']=400
            result=probe.inspect({})
        self.assertEqual(request.call_count,5)
        self.assertEqual((result['underlines'],result['thought_ranges'],result['thought_items']),(1,1,1))
        for value in (BOOK,'private thought','private source quote'):
            self.assertNotIn(value,json.dumps(result))

    def test_child_failure_discards_private_data_and_preserves_saved_grant(self):
        credentials=dict(vid='88008800',accessToken='private-access-token')
        probe=SimpleNamespace(inspect=lambda *_:dict(underlines=1),samples=[dict(private='private-source')],report=dict(stages=[]))
        with patch.object(native,'SessionStore') as web,patch.object(native,'NativeSessionStore') as store, \
                patch.object(native,'AnnotationProbe',return_value=probe),patch.object(native.subprocess,'run',return_value=
                    SimpleNamespace(returncode=1,stdout=b'private-output')) as child,redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='88008800')
            store.return_value.load.return_value=credentials
            self.assertEqual(native.main(['--saved-session','--native-http','--lua-command','synthetic']),1)
        self.assertIn('private-access-token',child.call_args.kwargs['input'].decode())
        self.assertEqual(credentials,{})
        store.return_value.delete.assert_not_called()
        for value in ('private-access-token','private-source','private-output','88008800'):
            self.assertNotIn(value,out.getvalue())

    def test_comparison_only_allows_stock_wire_rounding_of_display_heat_score(self):
        score=1.234567890123456
        original=[dict(underlines=[dict(range='12-45',score=score)])]
        rounded=[dict(underlines=[dict(range='12-45',score=float(format(score,'.14g')))])]
        self.assertIsNone(native.projection_difference(original,rounded))
        rounded[0]['underlines'][0]['score']=1.2345678901236
        self.assertIsNotNone(native.projection_difference(original,rounded))
        self.assertIsNotNone(native.projection_difference([dict(bookId=9007199254740993)],[dict(bookId=9007199254740992)]))
        self.assertIsNotNone(native.projection_difference([dict(count=1)],[dict(count=True)]))
        self.assertIsNone(native.projection_difference([dict(count=1)],[dict(count=1.0)]))
        result=native.projection_difference([dict(content='private original')],[dict(content='private changed')])
        self.assertNotIn('private',json.dumps(result))
        self.assertEqual(result['kind'],'value')


if __name__ == '__main__':
    unittest.main()
