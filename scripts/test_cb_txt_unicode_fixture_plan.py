import copy
import unittest

from cb_txt_unicode_fixture_plan import CONTEXT, EMOJI, plan
from test_cb_fixture_position import fixture
from txt_coordinates import PlainSource
from verify_cb_txt_fixture import MARKER
from verify_source_coordinates import CoordinateError


class UnicodeFixturePlanTest(unittest.TestCase):
    def sample(self):
        book,value=fixture()
        value.update(source_format='web_txt',source='\ufeff'+MARKER+'\r\n'+CONTEXT+'\r\n')
        return book,value

    def test_non_bmp_boundaries_and_surrogate_rejection(self):
        book,sample=self.sample();result=plan(book,sample);model=PlainSource(sample['source'])
        self.assertEqual(result['following']-result['first'],2)
        self.assertEqual(model.excerpt(result['first'],1)['text'],EMOJI)
        self.assertEqual(model.excerpt(result['following'],1)['text'],'B')
        with self.assertRaises(CoordinateError):model.excerpt(result['first']+1,1)

    def test_missing_duplicate_or_wrong_scope_is_rejected(self):
        book,sample=self.sample()
        for change in (dict(source=sample['source'].replace(EMOJI,'X')),
                       dict(source=sample['source']+CONTEXT),dict(book_id='CB_Other'),
                       dict(source_format='web_xhtml'),dict(baseline=dict(chapter='1',offset=0,percent=0))):
            value=copy.deepcopy(sample);value.update(change)
            with self.subTest(change=change),self.assertRaises(ValueError):plan(book,value)


if __name__=='__main__':unittest.main()
