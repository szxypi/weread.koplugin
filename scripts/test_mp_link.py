import contextlib
import io,json,unittest
from unittest.mock import patch
from urllib.error import HTTPError
from verify_mp_link import canonical,metadata,public_read,LinkError,main


class LinkTests(unittest.TestCase):
    def setUp(self):
        self.long='https://mp.weixin.qq.com/s?__biz=MzAxNDU2Nzg5MA%3D%3D&mid=2247483648&idx=1&sn='+('a'*32)
    def test_canonical_share_forms(self):
        self.assertEqual(canonical('https://mp.weixin.qq.com/s/synthetic_123?scene=1#rd'),'https://mp.weixin.qq.com/s/synthetic_123')
        self.assertEqual(canonical(self.long+'&scene=1&appmsg_token=discarded#wechat_redirect'),self.long)
        self.assertIsNone(canonical(self.long+'&idx=2'))
    def test_untrusted_urls_rejected(self):
        for bad in ('http://mp.weixin.qq.com/s/synthetic_123','https://mp.weixin.qq.com.evil/s/synthetic_123',
                    'https://mp.weixin.qq.com:443/s/synthetic_123','https://user@mp.weixin.qq.com/s/synthetic_123',
                    'https://mp.weixin.qq.com/s/../secret','https://mp.weixin.qq.com/s/%2Fsecret',self.long.replace('idx=1','idx=0')):
            self.assertIsNone(canonical(bad))
    def test_html_metadata(self):
        value=metadata('<meta property="og:url" content="'+self.long.replace('&','&amp;')+'"/><meta property="og:title" content="A &amp; B"><meta name="author" content="Publisher">')
        self.assertEqual(value.source,self.long);self.assertEqual(value.title,'A & B');self.assertEqual(value.author,'Publisher')
    def test_public_request_carries_no_owner_authorization(self):
        class Opener:
            def open(self,request,**_kwargs):
                self.request=request
                response=io.BytesIO(b'<body>synthetic</body>');response.status=200;return response
        opener=Opener();raw,report=public_read(self.long,opener)
        self.assertEqual(raw,'<body>synthetic</body>');self.assertEqual(report['status'],200)
        self.assertIsNone(opener.request.get_header('Cookie'));self.assertIsNone(opener.request.get_header('Authorization'))
        with self.assertRaises(LinkError):public_read('https://evil.test/',opener)
    def test_redirect_not_followed_or_exposed(self):
        class Opener:
            def open(self,request,**_kwargs):raise HTTPError(request.full_url,302,'private redirect',{},None)
        body,report=public_read(self.long,Opener());self.assertIsNone(body);self.assertEqual(report['status'],302)
        self.assertNotIn('private',json.dumps(report))
    def test_verification_redirect_is_only_classified(self):
        class Opener:
            def open(self,request,**_kwargs):
                raise HTTPError(request.full_url,302,'private',{'Location':'https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?target_url=private-value'},None)
        body,report=public_read(self.long,Opener())
        self.assertIsNone(body);self.assertEqual(report['redirect_kind'],'verification')
        self.assertEqual(report['redirects_followed'],0);self.assertNotIn('private',json.dumps(report))
    def test_default_never_loads_credentials(self):
        with patch('verify_mp_link.SessionStore',side_effect=AssertionError('Keychain')),contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0)
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
