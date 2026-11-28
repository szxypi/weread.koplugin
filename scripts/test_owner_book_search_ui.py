"""Owner UI acceptance stays offline by default and checks its worker report."""
import contextlib
import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import verify_owner_book_search_ui as task


class OwnerBookSearchUITests(unittest.TestCase):
    def test_default_never_opens_credentials_or_processes(self):
        for args in ([],['--missing-chapter'],['--missing-catalog']):
            output=io.StringIO()
            with patch.object(task,'SessionStore',side_effect=AssertionError('credentials')):
                with patch.object(task.subprocess,'run',side_effect=AssertionError('process')):
                    with contextlib.redirect_stdout(output):self.assertEqual(task.main(args),0)
            self.assertEqual(json.loads(output.getvalue()),{'result':'OFFLINE_ONLY','account_data_posts':0,
                'authentication_posts':0,'screenshots':0})

    def test_worker_must_report_verified_read_only_navigation(self):
        result={'result':'PASS','profile_removed':True,'installed_bytes_match':True,
            'account_data_posts':0,'authentication_posts':0,'ui':{'result':'PASS','native_menu':True,
            'search_result_verified':True,'source_navigation':True,'workers_reaped':True,
            'account_gets':1,'search_gets':1,'denied_requests':0}}
        def invoke(value,code=0):
            response=SimpleNamespace(returncode=code,stdout=json.dumps(value).encode())
            with patch.object(task.subprocess,'run',return_value=response):
                return task.invoke({'allowed':[{}]},'container','/runtime','/source','/candidate',600,800,167)
        self.assertEqual(invoke(result),result)
        for field,value in [('source_navigation',False),('workers_reaped',False),('search_gets',True),
                ('denied_requests',False),('account_gets',2)]:
            changed={**result,'ui':{**result['ui'],field:value}}
            with self.subTest(field=field),self.assertRaises(ValueError):invoke(changed)
        with self.assertRaises(ValueError):invoke({**result,'account_data_posts':1})
        with self.assertRaises(ValueError):invoke(result,1)

    def test_missing_chapter_requires_confirmed_download_and_cancel_proof(self):
        ui={'result':'PASS','native_menu':True,'search_result_verified':True,'source_navigation':True,
            'workers_reaped':True,'account_gets':1,'search_gets':1,'denied_requests':0,
            'download_confirmed':True,'cancel_without_download':True,'downloaded_source_verified':True,
            'credential_audit':True,'download_gets':2,'catalog_posts':1,'content_posts':4}
        report={'result':'PASS','profile_removed':True,'installed_bytes_match':True,
            'account_data_posts':0,'authentication_posts':0,'ui':ui}
        def invoke(value):
            response=SimpleNamespace(returncode=0,stdout=json.dumps(value).encode())
            with patch.object(task.subprocess,'run',return_value=response):
                return task.invoke({'allowed':[{}],'download_missing':True},'container','/runtime','/source','/candidate',600,800,167)
        self.assertEqual(invoke(report),report)
        for field,value in [('cancel_without_download',False),('downloaded_source_verified',False),
                ('credential_audit',False),('catalog_posts',0),('content_posts',True)]:
            with self.subTest(field=field),self.assertRaises(ValueError):
                invoke({**report,'ui':{**ui,field:value}})
        with self.assertRaises(ValueError):invoke({**report,'ui':{k:v for k,v in ui.items() if k!='download_confirmed'}})

    def test_missing_catalog_requires_cache_and_read_only_evidence(self):
        ui={'result':'PASS','native_menu':True,'search_result_verified':True,'source_navigation':True,
            'workers_reaped':True,'account_gets':2,'search_gets':2,'denied_requests':0,
            'catalog_restored':True,'credential_audit':True,'catalog_gets':1,'catalog_read_posts':1}
        report={'result':'PASS','profile_removed':True,'installed_bytes_match':True,
            'account_data_posts':0,'authentication_posts':0,'ui':ui}
        def invoke(value):
            response=SimpleNamespace(returncode=0,stdout=json.dumps(value).encode())
            with patch.object(task.subprocess,'run',return_value=response):
                return task.invoke({'allowed':[{},{}],'catalog_missing':True},'container','/runtime','/source','/candidate',600,800,167)
        self.assertEqual(invoke(report),report)
        for field,value in [('catalog_restored',False),('credential_audit',False),('catalog_gets',0),('catalog_read_posts',True)]:
            with self.subTest(field=field),self.assertRaises(ValueError):invoke({**report,'ui':{**ui,field:value}})

    def test_readable_catalog_matches_download_filter(self):
        rows=[{'title':'封面','wordCount':10},{'title':'空章','wordCount':0},
            {'title':'正文','wordCount':'15'},{'title':'正文二','wordCount':5},
            {'title':'异常','wordCount':True}]
        self.assertEqual(task.readable_catalog(rows),rows[2:4])


if __name__=='__main__':unittest.main()
