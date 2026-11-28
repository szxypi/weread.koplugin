"""No network: group trial dispatch, readback, lag and interruption tests."""
from copy import deepcopy
import unittest

from cloud_group_journal import Journal
from cloud_group_trial import Trial


class Memory:
    def __init__(self): self.raw = None
    def load(self): return self.raw
    def save(self, value): self.raw = value


def shelf(native):
    group = {'archiveId': 2, 'name': 'Synthetic', 'bookIds': ['42']}
    data = {'books': [{'bookId': '42', 'title': 'Synthetic', 'finishReading': 0, 'secret': 0}], 'archive': [group]}
    if native: data['albums'] = []; group['albumIds'] = []
    return data


class Fake:
    def __init__(self):
        self.native, self.web = shelf(True), shelf(False)
        self.posts, self.mode, self.valid, self.reads = [], None, True, 0
        self.journal = Journal(backend=Memory())
        self.trial = Trial(self.journal, self.read, self.post, lambda: self.valid, sleep=lambda _s: None)

    def read(self):
        self.reads += 1
        return dict(native=deepcopy(self.native), web=deepcopy(self.web))

    def post(self, path, body):
        self.posts.append((path, deepcopy(body)))
        if path == '/shelf/archive':
            for native, value in ((True, self.native), (False, self.web)):
                group = {'archiveId': 42, 'name': body['name'], 'bookIds': []}
                if native: group['albumIds'] = []
                value['archive'].append(group)
            if self.mode == 'unrelated': self.native['books'][0]['secret'] = 1
            if self.mode == 'create_lost': raise OSError('synthetic')
        elif path == '/shelf/deleteArchive':
            assert body == {'archiveId': 42, 'removeBooks': 0}
            self.native['archive'].pop(); self.web['archive'].pop()
            if self.mode == 'delete_lost': raise OSError('synthetic')
        else: raise AssertionError('unexpected endpoint')
        return {'succ': 1}

    def run(self): return self.trial.run('42', 'a' * 64)


class CloudGroupTrialTest(unittest.TestCase):
    def test_success_has_exactly_two_one_shot_writes_and_full_readback(self):
        fake = Fake(); result = fake.run()
        self.assertEqual(result['result'], 'PASS'); self.assertEqual(result['data_posts'], 2)
        self.assertEqual([item[0] for item in fake.posts], ['/shelf/archive', '/shelf/deleteArchive'])
        self.assertEqual(fake.posts[0][1]['bookIds'], []); self.assertEqual(fake.posts[0][1]['albumIds'], [])
        self.assertEqual(fake.journal.read()[0]['phase'], 'restored')
        reads=fake.reads
        self.assertEqual(fake.run()['data_posts'], 0)
        self.assertEqual(fake.reads,reads)

    def test_lost_create_or_delete_never_replays(self):
        for mode, count, phase in (('create_lost', 1, 'create_claimed'), ('delete_lost', 2, 'delete_claimed')):
            with self.subTest(mode=mode):
                fake = Fake(); fake.mode = mode; result = fake.run()
                self.assertEqual(result['result'], 'UNVERIFIED'); self.assertEqual(len(fake.posts), count)
                self.assertEqual(fake.journal.read()[0]['phase'], phase)
                self.assertEqual(fake.run()['data_posts'], 0); self.assertEqual(len(fake.posts), count)

    def test_changed_shelf_or_missing_album_visibility_never_claims_delete(self):
        fake = Fake(); fake.mode = 'unrelated'; result = fake.run()
        self.assertEqual(result['result'], 'UNVERIFIED'); self.assertEqual(len(fake.posts), 1)
        self.assertEqual(fake.journal.read()[0]['phase'], 'create_claimed')
        fake = Fake(); fake.native.pop('albums'); result = fake.run()
        self.assertEqual(result['data_posts'], 0); self.assertIsNone(fake.journal.read()[0])
        fake = Fake(); fake.native['archive'][0].pop('albumIds'); result = fake.run()
        self.assertEqual(result['data_posts'], 0); self.assertIsNone(fake.journal.read()[0])

    def test_interrupted_create_remains_sealed_and_never_deletes(self):
        fake = Fake(); original = fake.post
        def post(path, body):
            value = original(path, body); fake.valid = False; return value
        fake.trial.post = post; result = fake.run()
        self.assertEqual(result['result'], 'UNVERIFIED'); self.assertEqual(len(fake.posts), 1)
        self.assertEqual(fake.journal.read()[0]['phase'], 'create_claimed')

    def test_lagging_web_snapshot_is_read_back_without_repeating_a_write(self):
        fake = Fake(); original_post, original_read = fake.post, fake.read
        lag = []
        def post(path, body):
            old = deepcopy(fake.web); response = original_post(path, body); lag.append(old); return response
        def read():
            pair = original_read()
            if lag: pair['web'] = lag.pop(0)
            return pair
        fake.trial.post, fake.trial.read_pair = post, read
        result = fake.run()
        self.assertEqual(result['result'], 'PASS'); self.assertEqual(len(fake.posts), 2)
        self.assertEqual(fake.journal.read()[0]['phase'], 'restored')

    def test_other_change_during_delete_stops_confirmation(self):
        fake = Fake(); original = fake.post
        def post(path, body):
            response = original(path, body)
            if path == '/shelf/deleteArchive': fake.native['books'][0]['secret'] = 1
            return response
        fake.trial.post = post; result = fake.run()
        self.assertEqual(result['result'], 'UNVERIFIED'); self.assertEqual(len(fake.posts), 2)
        self.assertEqual(fake.journal.read()[0]['phase'], 'delete_claimed')


if __name__ == '__main__': unittest.main()
