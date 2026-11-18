import copy
import unittest

from cb_fixture_position import body, validate
from cb_txt_initial_fixture_plan import plan
from test_cb_fixture_position import fixture
from verify_cb_txt_fixture import MARKER


def txt_fixture(prefix=''):
    book, sample = fixture()
    sample.update(source_format='web_txt', source=prefix + MARKER + '\nA distinct synthetic line.\n')
    return book, sample


class TxtInitialPlanTest(unittest.TestCase):
    def test_raw_utf16_boundary_and_existing_scoped_request(self):
        book, sample = txt_fixture('😀\r\n')
        target = plan(book, sample)
        self.assertEqual(target['first'], 8)  # astral scalar, CRLF, then four ASCII scalars
        self.assertEqual(target['following'], 9)
        request = body(target, 'enter')
        self.assertTrue(validate(target, 'enter', request))
        self.assertEqual(request['co'], target['first'])
        self.assertFalse(any(key in request for key in ('rt', 'ts', 'rn', 'sg')))

    def test_rejects_wrong_scope_source_and_ambiguous_source(self):
        book, sample = txt_fixture()
        for mutation in (
            {'book_id': 'CB_Other'}, {'source_format': 'web_xhtml'}, {'source': 'unrelated'},
            {'source': MARKER + '\n' + MARKER}, {'chapters': []},
            {'baseline': dict(chapter='1', offset=0, percent=0)},
            {'baseline': dict(chapter='0', offset=False, percent=0)},
            {'baseline': dict(chapter='0', offset=0, percent=False)},
        ):
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                plan(book, dict(sample, **mutation))

    def test_requires_unique_chapter_and_unstarted_reader(self):
        book, sample = txt_fixture()
        changed = copy.deepcopy(sample)
        changed['chapters'].append(dict(changed['chapters'][0]))
        with self.assertRaises(ValueError): plan(book, changed)
        changed = copy.deepcopy(sample)
        changed['chapters'][0]['chapterIdx'] = True
        with self.assertRaises(ValueError): plan(book, changed)
        changed = copy.deepcopy(sample)
        changed['context']['progress']['book']['chapterOffset'] = 1
        with self.assertRaises(ValueError): plan(book, changed)
        changed = copy.deepcopy(sample)
        changed['context']['book_id'] = 'CB_Other'
        with self.assertRaises(ValueError): plan(book, changed)

    def test_prefix_ambiguity_and_invalid_raw_text_fail_closed(self):
        book, sample = txt_fixture('prefix ' + MARKER[4:] + '\n')
        with self.assertRaises(ValueError): plan(book, sample)
        book, sample = txt_fixture('\x00')
        with self.assertRaises(ValueError): plan(book, sample)


if __name__ == '__main__': unittest.main()
