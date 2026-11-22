"""Offline tests for the private full-download validation boundary."""
from contextlib import redirect_stdout
import io
import json
import subprocess
import sys
import unittest
from unittest.mock import patch

import verify_native_full_book_owner as subject


class OwnerFullBookValidation(unittest.TestCase):
    def run_fixture(self, offline=True, live=True):
        rows=[dict(uid=1,wordCount=300,free_or_owned=True),dict(uid=2,wordCount=300,free_or_owned=True)]
        sample=dict(book_id='123',expected=dict(version=7,chapters=rows))
        result=dict(ok=True,owner=True,chapters=2,styles=1,images=2,live_web=live,credential_audit=live)
        stdout=b'WEREAD_FULL_RESULT='+json.dumps(result).encode()+b'\n'
        if offline:
            stdout+=b'WEREAD_FULL_OFFLINE_RESULT='+json.dumps(dict(ok=True,chapters=2,images=2,network_blocked=True)).encode()+b'\n'
        argv=['verify','--saved-session']+(['--live-web'] if live else [])+['--lua-command','fixture']
        with patch.object(sys,'argv',argv),patch.object(subject.resource,'setrlimit'),\
             patch.object(subject,'SessionStore') as saved,patch.object(subject,'NativeSessionStore') as native,\
             patch.object(subject,'ChapterProbe') as probe,patch.object(subject,'TranslationWebProbe') as web,\
             patch.object(subject,'search_token',return_value='sample'),patch.object(subject.subprocess,'run') as child,\
             redirect_stdout(io.StringIO()) as output:
            saved.return_value.load.return_value=dict(vid='12345678',cookies=dict(wr_vid='12345678',wr_skey='private-cookie'))
            native.return_value.load.return_value=dict(vid='12345678',accessToken='private-access')
            probe.return_value.inspect.return_value=(sample,rows[0],{})
            web.return_value.content_sample=dict(source='<p>private source</p>')
            web.return_value.inspect_content.return_value=dict(content_decoded=True)
            child.return_value=subprocess.CompletedProcess(['fixture'],0,stdout,b'private stderr')
            code=subject.main()
            payload=json.loads(child.call_args.kwargs['input'])
        self.assertNotIn('private-cookie',output.getvalue())
        self.assertNotIn('private-access',output.getvalue())
        self.assertNotIn('private source',output.getvalue())
        return code,json.loads(output.getvalue()),payload

    def test_live_requires_offline_process_and_keeps_credentials_in_input(self):
        code,report,payload=self.run_fixture()
        self.assertEqual(code,0)
        self.assertTrue(report['offline_new_process'])
        self.assertTrue(report['temporary_files_credential_audit'])
        self.assertEqual(payload['cookies']['wr_skey'],'private-cookie')

    def test_missing_offline_result_is_not_reported_as_pass(self):
        code,report,_=self.run_fixture(offline=False)
        self.assertEqual(code,1)
        self.assertEqual(report['result'],'UNVERIFIED')

    def test_injected_source_mode_remains_distinct(self):
        code,report,payload=self.run_fixture(offline=False,live=False)
        self.assertEqual(code,0)
        self.assertFalse(report['live_web_download'])
        self.assertNotIn('cookies',payload)


if __name__=='__main__':
    unittest.main()
