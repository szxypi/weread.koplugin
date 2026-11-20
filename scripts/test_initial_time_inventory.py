"""Read-only first-position inventory boundaries."""
import contextlib
import io
import json
import unittest
from unittest.mock import patch

import verify_initial_time_inventory as inventory


def absent(**kwargs):
    return dict(progress=0, chapterUid=0, chapterOffset=0,
                readingTime=kwargs.get('readingTime', 0), recordReadingTime=0, ttsTime=0)


class Api:
    def __init__(self, values, after=None):
        self.values = values; self.allowed = set(); self.calls = []; self.after = after
    def request(self, stage, url, body=None, credentials=None):
        self.calls.append((stage, url, body))
        if stage.startswith('shelf'):
            return {'books': [{'bookId': k} for k in (self.after if stage == 'shelf_after' and self.after is not None else self.values)]}
        ident = url.split('bookId=')[1]
        if ident not in self.allowed or body is not None: raise AssertionError('scope')
        value = self.values[ident]
        return value.pop(0) if isinstance(value, list) else value


class Web:
    def __init__(self): self.book_id = None; self.calls = []
    def request(self, stage, url):
        self.calls.append(stage)
        return absent()


class InventoryTest(unittest.TestCase):
    def run_case(self, api, web=None):
        with patch.object(inventory, 'shelf_projection', lambda shelf: shelf):
            return inventory.inspect(api, web or Web(), {}, 0, 10, pause=lambda _: None)

    def test_offline_default_does_not_access_credentials(self):
        with patch.object(inventory, 'SessionStore', side_effect=AssertionError), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(inventory.main([]), 0)
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')

    def test_no_position_and_counter_types_are_not_inferred(self):
        self.assertEqual(inventory.classify(absent(), '1')[0], 'zero')
        self.assertEqual(inventory.classify(absent(readingTime=1), '1')[0], 'nonzero')
        for key in ('recordReadingTime','ttsTime'):
            value=absent();value[key]=1
            self.assertEqual(inventory.classify(value, '1')[0], 'nonzero')
        missing=absent(); del missing['ttsTime']
        self.assertEqual(inventory.classify(missing, '1')[0], 'missing_counts')
        self.assertEqual(inventory.classify({'progress':50, 'chapterUid':1, 'chapterOffset':4}, '1')[0], 'other_or_unverified')
        self.assertEqual(inventory.classify(absent(readingTime=True), '1')[0], 'missing_counts')

    def test_counts_and_shelf_readback(self):
        api=Api({'1': absent(), '2': {'progress':25,'chapterUid':1,'chapterOffset':10}})
        result=self.run_case(api)
        self.assertEqual((result['checked'], result['zero'], result['other_or_unverified']), (2, 1, 1))
        self.assertTrue(result['shelf_unchanged']); self.assertEqual(len(api.calls), 4)
        self.assertTrue(all(body is None for _,_,body in api.calls))

    def test_candidate_is_checked_twice_on_both_channels_and_stops(self):
        api=Api({'1': absent(), '2': [absent(readingTime=3), absent(readingTime=3)], '3': absent()}); web=Web()
        result=self.run_case(api, web)
        self.assertEqual((result['checked'], result['nonzero'], result['candidate_shelf_ordinal']), (2, 1, 2))
        self.assertTrue(result['candidate_dual_channel_stable']); self.assertEqual(web.calls, ['progress_before','progress_after'])
        self.assertFalse(any('bookId=3' in url for _,url,_ in api.calls))

    def test_candidate_change_stops_without_more_reads(self):
        api=Api({'1': [absent(readingTime=3), absent(readingTime=4)], '2': absent()})
        with self.assertRaises(ValueError): self.run_case(api)
        self.assertFalse(any('bookId=2' in url for _,url,_ in api.calls))

    def test_request_error_stops_the_inventory(self):
        class Failing(Api):
            def request(self, stage, url, body=None, credentials=None):
                if 'bookId=2' in url: raise RuntimeError('429')
                return super().request(stage, url, body, credentials)
        api=Failing({'1': absent(), '2': absent(), '3': absent()})
        with self.assertRaises(RuntimeError): self.run_case(api)
        self.assertFalse(any('bookId=3' in url for _,url,_ in api.calls))
        self.assertFalse(any(stage=='shelf_after' for stage,_,_ in api.calls))

    def test_web_position_change_cannot_prove_candidate(self):
        class ChangedWeb(Web):
            def request(self, stage, url):
                return absent() if stage=='progress_before' else {'progress':10,'chapterUid':1,'chapterOffset':2}
        api=Api({'1': [absent(readingTime=3), absent(readingTime=3)]})
        with self.assertRaises(ValueError): self.run_case(api, ChangedWeb())

    def test_changed_shelf_is_not_accepted(self):
        api=Api({'1': absent(), '2': absent()}, after=['2','1'])
        with self.assertRaises(ValueError): self.run_case(api)

    def test_scope_rejects_writes_and_unselected_ids(self):
        grant={'vid':'1','accessToken':'not-a-real-token'}
        api=inventory.ScopedNative(grant);api.allowed={'123'}
        for url, body in ((inventory.NATIVE_BASE+'/shelf/sync', {}),
                          (inventory.NATIVE_BASE+'/book/getProgress?bookId=124', None),
                          ('https://evil.invalid/book/getProgress?bookId=123', None),
                          (inventory.NATIVE_BASE+'/book/getProgress?bookId=123&extra=', None)):
            with self.assertRaises(ValueError): api.request('progress', url, body=body, credentials=grant)
        self.assertEqual(api.report['stages'], [])

    def test_duplicates_and_unsafe_numeric_ids(self):
        with self.assertRaises(ValueError): inventory.numeric_books({'books':[{'bookId':'12'},{'bookId':12}]})
        self.assertEqual(inventory.numeric_books({'books':[{'bookId':9007199254740992},{'bookId':'9007199254740992'}, {'bookId':'CB_a'}]}), ['9007199254740992'])


if __name__ == '__main__': unittest.main()
