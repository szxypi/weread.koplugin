import unittest
from copy import deepcopy

from cb_cloud_position import observed
from verify_cb_initial_observation import lua_projection, summarize


BOOK = 'CB_TestFixture'


def response(**changes):
    value = dict(bookId=BOOK, progress=0, chapterUid=0, chapterOffset=0,
                 chapterIdx=0, summary='', readingTime=0, recordReadingTime=0, ttsTime=0)
    value.update(changes)
    return value


def pair(native, web):
    n = observed(native, BOOK, [], 'native')
    w = observed(web, BOOK, [], 'web')
    return dict(native=[n, deepcopy(n)], web=[w, deepcopy(w)])


class InitialObservationTest(unittest.TestCase):
    def test_explicit_zero_and_nonzero_counters(self):
        result = summarize([pair(response(), response()),
                            pair(response(readingTime=3), response())])
        self.assertEqual((result['both_no_chapter'], result['native_zero_counts'],
                          result['native_counts_nonzero']), (2, 1, 1))

    def test_missing_counter_is_not_zero(self):
        raw = response(); del raw['ttsTime']
        result = summarize([pair(raw, response())])
        self.assertEqual(result['native_counts_incomplete'], 1)
        self.assertEqual(result['native_zero_counts'], 0)

    def test_missing_and_positive_position_are_not_no_chapter(self):
        raw = response(); del raw['chapterOffset']
        result = summarize([pair(raw, response()),
                            pair(response(chapterUid=12), response(chapterUid=12))])
        self.assertEqual((result['mixed_no_chapter'], result['neither_no_chapter']), (1, 1))

    def test_change_between_reads_fails(self):
        sample = pair(response(), response())
        sample['native'][1]['counters']['readingTime']['value'] = 1
        with self.assertRaises(ValueError): summarize([sample])

    def test_missing_channel_fails(self):
        with self.assertRaises(ValueError): summarize([{'native': []}])

    def test_private_lua_projection_emits_only_presence(self):
        raw = response(updateTime=123)
        self.assertEqual(lua_projection({'book': raw}, BOOK),
                         dict(recognized=True, index_present=True, summary_present=True, updated_present=True))
        raw['chapterTitle'] = 'conflicting value'
        self.assertEqual(lua_projection({'book': raw}, BOOK), dict(recognized=False))
        self.assertNotIn(BOOK, repr(lua_projection({'book': raw}, BOOK)))


if __name__ == '__main__': unittest.main()
