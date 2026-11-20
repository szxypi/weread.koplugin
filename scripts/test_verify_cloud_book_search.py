"""The search preflight is offline by default and narrowly scoped."""
import contextlib
import io
import json
import unittest
from unittest.mock import patch

import verify_cloud_book_search as task
from verify_web_source_progress import PreflightError


class SearchPreflightTests(unittest.TestCase):
    def test_default_does_not_load_credentials_or_start_processes(self):
        output=io.StringIO()
        with patch.object(task,'SessionStore',side_effect=AssertionError('must not open credentials')):
            with patch.object(task.subprocess,'run',side_effect=AssertionError('must not start process')):
                with contextlib.redirect_stdout(output):self.assertEqual(task.main([]),0)
        self.assertEqual(json.loads(output.getvalue()),{'result':'OFFLINE_ONLY','account_data_posts':0,
            'authentication_posts':0,'search_gets':0})

    def test_search_guard_requires_authenticated_exact_url_and_get(self):
        probe=task.Probe();probe.search_url=task.BASE+'/web/book/search_v2?bookId=123'
        try:
            with self.assertRaises(PreflightError):probe.guard('search_probe',probe.search_url,None)
            probe.authenticated=True
            probe.guard('search_probe',probe.search_url,None)
            for url,body in ((probe.search_url,{}),(probe.search_url+'0',None),('https://example.invalid/search',None)):
                with self.assertRaises(PreflightError):probe.guard('search_probe',url,body)
            probe.search_url='https://example.invalid/search'
            with self.assertRaises(PreflightError):probe.guard('search_probe',probe.search_url,None)
        finally:probe.close()


if __name__=='__main__':unittest.main()
