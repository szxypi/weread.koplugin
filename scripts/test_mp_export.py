import contextlib
import io
import json
import subprocess
import unittest
from unittest.mock import patch
from verify_mp_export import ExportProbe, MPError, KNOWN_REVIEW, compare, child, main, body_of


class ExportTests(unittest.TestCase):
    def test_text_and_missing_image_projection(self):
        self.assertEqual(compare('<p>A &amp; 中文</p><img alt="说明"/><script>secret</script>',
            '<p>A &amp; 中文</p><span>[说明]</span>'),1)
        self.assertEqual(compare('<svg><text>foreign</text></svg><p>正文</p>','<p>正文</p>'),0)
        with self.assertRaises(MPError): compare('<p>original</p>','<p>changed</p>')
        with self.assertRaises(MPError): compare('<p>text</p><img/>','<p>text</p><img/>')

    def test_body_matches_existing_extraction(self):
        self.assertEqual(body_of('<div id="js_content"><p>正文</p><img data-src="url"/></div><script>x</script>'),'<p>正文</p><img src="url"/>')
        with self.assertRaises(MPError): body_of('<p>not an article</p>')

    def test_exact_read_only_transport(self):
        probe=ExportProbe()
        try:
            probe.authenticated=True
            probe.guard('mp_content','https://weread.qq.com/web/mp/content?reviewId='+KNOWN_REVIEW,None)
            for stage,url,body in (
                ('mp_content','https://weread.qq.com/web/mp/content?reviewId=other',None),
                ('mp_content','https://weread.qq.com/web/mp/content?reviewId='+KNOWN_REVIEW,{}),
                ('mp_catalog','https://weread.qq.com/web/mp/articles',None),
                ('web_renewal','https://weread.qq.com/web/login/renewal',{})):
                with self.assertRaises(MPError): probe.guard(stage,url,body)
        finally: probe.close()

    def test_child_output_private_and_bounded(self):
        frame=b'\nWEREAD_MP_EXPORT_RESULT='
        for output,code in ((b'private child error',1),(b'private child log',0),(frame+b'bad',0),(frame+b'{}'+frame+b'{}',0)):
            with patch('verify_mp_export.subprocess.run',return_value=subprocess.CompletedProcess([],code,output,b'private stderr')):
                with self.assertRaisesRegex(MPError,'export/probe_failed'): child(['unused'],{})
        with patch('verify_mp_export.subprocess.run',return_value=subprocess.CompletedProcess([],0,frame+b'{"requests":1}',b'')):
            self.assertEqual(child(['unused'],{}),{'requests':1})

    def test_default_does_not_access_credentials_or_network(self):
        with patch('verify_mp_export.SessionStore',side_effect=AssertionError('Keychain opened')):
            out=io.StringIO()
            with contextlib.redirect_stdout(out): self.assertEqual(main([]),0)
            report=json.loads(out.getvalue())
            self.assertEqual(report['result'],'OFFLINE_ONLY')
            self.assertEqual(report['account_data_writes_attempted'],0)


if __name__=='__main__': unittest.main()
