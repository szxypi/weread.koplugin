"""No live credentials or account writes are permitted by this test."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch
import verify_cb_roundtrip_preflight as task
from verify_source_coordinates import FilteredSource


class TestCbRoundtripPreflight(unittest.TestCase):
    def test_offline_does_not_access_session(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'Web') as web,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();web.assert_not_called()
        report=json.loads(out.getvalue());self.assertEqual(report['result'],'OFFLINE_ONLY')
        self.assertEqual(report['account_data_writes'],0);self.assertFalse(report['write_authority_granted'])

    def test_exact_original_and_adjacent_character_required(self):
        book='CB_Synthetic';source='<html><body><p>Unique synthetic position with enough surrounding text.</p></body></html>'
        offset=FilteredSource(source).starts[0]
        point=dict(bookId=book,chapterUid=2,chapterIdx=2,chapterOffset=offset,progress=25,summary='synthetic')
        raw=dict(book=point);context=dict(book_id=book,psvts='synthetic',pclts='synthetic',token='synthetic',progress=raw)
        long_raw=dict(book=dict(point,summary='x'*21))
        long_plan=task.assess(book,long_raw,dict(context,progress=long_raw),source)
        self.assertIsNotNone(long_plan);self.assertFalse(long_plan['same_position_summary_preserved'])
        from verify_position_roundtrip import payload
        self.assertLessEqual(len(payload(long_plan,'write_same')['sm']),20)
        plan=task.assess(book,raw,context,source)
        self.assertIsNotNone(plan);self.assertEqual(plan['target']['chapter_offset'],offset+1)
        wrong=dict(context,book_id='CB_Other');self.assertIsNone(task.assess(book,raw,wrong,source))
        self.assertIsNone(task.assess(book,raw,context,source+source))
        gap=dict(book=dict(point,chapterOffset=offset-1))
        self.assertIsNone(task.assess(book,gap,dict(context,progress=gap),source))


if __name__=='__main__':unittest.main()
