"""Exact book binding and sanitized evidence for uploaded EPUB native reading."""
import json,unittest
from synthetic_upload_epub import TEXT
from synthetic_upload_pdf import TEXT as PDF_TEXT
from verify_uploaded_epub_native_reading import verify

TARGET='CB_SyntheticReading'


class Store:
    def load(self):return dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock-private-cookie'))


class Probe:
    def __init__(self,contains=True):self.samples=[];self.contains=contains;self.closed=False
    def set_cookie(self,_key,_value):pass
    def verify_account(self):pass
    def request(self,stage,_url):
        assert stage=='shelf'
        return dict(books=[dict(bookId='CB_Other')]+([dict(bookId=TARGET)] if self.contains else []))
    def close(self):self.closed=True


class UploadedReadingTest(unittest.TestCase):
    def test_success_binds_exact_target_before_native_reader(self):
        probe=Probe();calls=[]
        def native(args,**scope):
            calls.append((args,scope));print(json.dumps(dict(result='CB_NATIVE_READING_VERIFIED',same_owner_verified=True,
                source_text_matched=True,fresh_offline_process=True,cloud_position_unchanged=True,source_format='web_xhtml',
                account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False,screenshots=0)));return 0
        value=verify(TARGET,store=Store(),probe_factory=lambda:probe,read_native=native,save_rotation=lambda *_:False)
        self.assertEqual(value['result'],'UPLOADED_EPUB_NATIVE_READING_VERIFIED');self.assertTrue(probe.closed)
        self.assertEqual(calls[0][1],dict(expected_book_id=TARGET,expected_source_text=TEXT))
        self.assertEqual(calls[0][0][2],'2');self.assertNotIn('mock-private-cookie',json.dumps(value))
    def test_missing_or_invalid_target_never_opens_native_reader(self):
        calls=[];probe=Probe(False)
        with self.assertRaises(ValueError):verify(TARGET,store=Store(),probe_factory=lambda:probe,read_native=lambda *_args,**_kw:calls.append(1),save_rotation=lambda *_:False)
        self.assertTrue(probe.closed);self.assertEqual(calls,[])
        with self.assertRaises(ValueError):verify('42',store=Store())
    def test_pdf_requires_fixed_source_and_reports_its_own_format(self):
        calls=[]
        def native(_args,**scope):
            calls.append(scope);print(json.dumps(dict(result='CB_NATIVE_SINGLE_PAGE_READING_VERIFIED',page_turn_tested=False,same_owner_verified=True,
                source_text_matched=True,fresh_offline_process=True,cloud_position_unchanged=True,source_format='web_xhtml',
                account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False,screenshots=0)));return 0
        value=verify(TARGET,store=Store(),probe_factory=Probe,read_native=native,save_rotation=lambda *_:False,expected_source_text=PDF_TEXT)
        self.assertEqual(value['result'],'UPLOADED_PDF_NATIVE_READING_VERIFIED');self.assertEqual(calls[0]['expected_source_text'],PDF_TEXT)
        self.assertIs(calls[0]['single_page'],True)
        with self.assertRaises(ValueError):verify(TARGET,store=Store(),expected_source_text='arbitrary private text')
    def test_multipage_pdf_keeps_the_page_turn_requirement(self):
        calls=[]
        def native(_args,**scope):
            calls.append(scope);print(json.dumps(dict(result='CB_NATIVE_READING_VERIFIED',same_owner_verified=True,
                source_text_matched=True,fresh_offline_process=True,cloud_position_unchanged=True,source_format='web_xhtml',
                account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False,screenshots=0)));return 0
        result=verify(TARGET,store=Store(),probe_factory=Probe,read_native=native,save_rotation=lambda *_:False,
            expected_source_text=PDF_TEXT,pdf_multipage=True)
        self.assertEqual(result['result'],'UPLOADED_PDF_NATIVE_READING_VERIFIED');self.assertTrue(result['page_turn_tested'])
        self.assertNotIn('single_page',calls[0])
        with self.assertRaises(ValueError):verify(TARGET,store=Store(),pdf_multipage=True)
    def test_incomplete_native_evidence_never_confirms_reading(self):
        for change in ('wrong_result','position','offline','write','screen'):
            def native(_args,**_scope):
                value=dict(result='CB_NATIVE_READING_VERIFIED',same_owner_verified=True,source_text_matched=True,
                    fresh_offline_process=True,cloud_position_unchanged=True,source_format='web_xhtml',account_data_posts=0,
                    authentication_posts=0,private_data_on_regular_disk=False,screenshots=0)
                if change=='wrong_result':value['result']='UNVERIFIED'
                elif change=='position':value['cloud_position_unchanged']=False
                elif change=='offline':value['fresh_offline_process']=False
                elif change=='write':value['account_data_posts']=1
                else:value['screenshots']=1
                print(json.dumps(value));return 0
            with self.subTest(change=change),self.assertRaises(ValueError):
                verify(TARGET,store=Store(),probe_factory=Probe,read_native=native,save_rotation=lambda *_:False)
    def test_failure_diagnostics_discard_unrecognized_text(self):
        diagnostics={}
        def native(_args,**_scope):
            print(json.dumps(dict(result='UNVERIFIED',ui=dict(result='UNVERIFIED',runner_error='private content',
                stages=[dict(result='UNVERIFIED',phase='private chapter',mode='live',failed_line=12,source_match_reason='private words')]))));return 1
        with self.assertRaises(ValueError):
            verify(TARGET,store=Store(),probe_factory=Probe,read_native=native,save_rotation=lambda *_:False,diagnostics=diagnostics)
        self.assertEqual(diagnostics['runner_error'],'other');self.assertNotIn('private',json.dumps(diagnostics))


if __name__=='__main__':unittest.main()
