import hashlib
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from fetch_weread_epub import fetch_chapter
from mock_weread import shards


TEXT='One synthetic TXT line.\nAnother distinct line.\n'


class Client:
    def __init__(self,second,*,failure=None,direct=True):
        self.first=shards(TEXT,1 if second in ('{}','',hashlib.md5(b'').hexdigest().upper()) else 2)[0]
        self.second=second;self.failure=failure;self.calls=[];self.direct=direct
    def get_text(self,*_args,**_kwargs):return 'synthetic reader'
    def request(self,url,**_kwargs):
        part=url.rsplit('/',1)[-1];self.calls.append(part)
        if part=='e_0':return b'{"bookId":"900001"}'
        if part=='t_0':return self.first.encode()
        if part=='t_1':
            if self.failure:raise self.failure
            return self.second.encode()
        raise AssertionError('unexpected route')


class TxtShardTests(unittest.TestCase):
    def fetch(self,client,direct):
        with patch('fetch_weread_epub.read_reader_state',return_value=SimpleNamespace(psvts='synthetic')):
            return fetch_chapter(client,book_id='900001',chapter={'chapterUid':1},sleep_seconds=0,
                                 content_format=['txt' if direct else 'epub'])

    def test_both_shards_and_explicit_empty_forms(self):
        for direct in (True,False):
            for second in (shards(TEXT,2)[1],'{}','',hashlib.md5(b'').hexdigest().upper()):
                with self.subTest(direct=direct,second_length=len(second)):
                    client=Client(second,direct=direct)
                    _title,html,_css,_assets=self.fetch(client,direct)
                    self.assertIn('Another distinct line.',html)
                    self.assertEqual(client.calls[-2:],['t_0','t_1'])

    def test_failed_invalid_or_corrupt_second_shard_never_returns_chapter(self):
        for direct in (True,False):
            for failure,second in ((TimeoutError(),''),(ValueError('HTTP failure'),''),(None,'{"errcode":-1}'),
                                   (None,'F'*32),(None,'F'*32+'bad')):
                with self.subTest(direct=direct,second_length=len(second)):
                    client=Client(second,failure=failure,direct=direct)
                    with self.assertRaises((ValueError,TimeoutError)):self.fetch(client,direct)
                    self.assertEqual(client.calls[-1],'t_1')

    def test_missing_or_malformed_first_shard_stops_before_second(self):
        for direct in (True,False):
            for first in ('{}','','F'*32,'invalid'):
                client=Client(shards(TEXT,2)[1],direct=direct);client.first=first
                with self.subTest(direct=direct,first=first),self.assertRaises(ValueError):self.fetch(client,direct)
                self.assertEqual(client.calls[-1],'t_0')

    def test_explicit_empty_second_preserves_request_pacing(self):
        client=Client('{}')
        with patch('fetch_weread_epub.read_reader_state',return_value=SimpleNamespace(psvts='synthetic')),\
             patch('fetch_weread_epub.time.sleep') as sleep:
            fetch_chapter(client,book_id='900001',chapter={'chapterUid':1},sleep_seconds=0.5,content_format=['txt'])
        self.assertEqual([call.args for call in sleep.call_args_list],[(0.5,),(0.5,)])


if __name__=='__main__':unittest.main()
