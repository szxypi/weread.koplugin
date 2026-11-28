import contextlib,io,json,unittest
from unittest.mock import patch
from verify_eink_login import BASE
from verify_mp_resolve import Probe,project,main,same_article


class ResolveTest(unittest.TestCase):
    def setUp(self):self.url='https://mp.weixin.qq.com/s/synthetic_123';self.review='MP_WXS_900000_synthetic'
    def test_matches_same_source_and_review(self):
        for value in (self.review,'synthetic'):
            self.assertEqual(project(self.url,{'reviewIds':[{'url':self.url,'reviewId':value}]},self.review),value)
    def test_rejects_missing_multiple_wrong_source_and_wrong_review(self):
        for raw in ({},{'reviewIds':[]},{'reviewIds':[{},{}]}, {'reviewIds':[{'url':'https://mp.weixin.qq.com/s/different_123','reviewId':self.review}]},
                {'reviewIds':[{'url':self.url,'reviewId':'wrong'}]},{'reviewIds':[{'url':self.url,'reviewId':'bad\nvalue'}]}):
            with self.subTest(raw=raw),self.assertRaises(ValueError):project(self.url,raw,self.review)
    def test_lookup_guard_blocks_other_requests_and_replay(self):
        api=Probe(self.url)
        for stage,url,body in (('lookup',BASE+'/mp/getreviewid',{'urls':[self.url,'https://evil.invalid']}),
                ('lookup',BASE+'/mp/getpaidinfo',{'urls':[self.url]}),('lookup',BASE+'/mp/getreviewid',{'urls':['https://evil.invalid']}),
                ('shelf',BASE+'/shelf/delete',{'bookIds':['900001']})):
            with self.assertRaises(ValueError):api.request(stage,url,body)
        api.lookups=1
        with self.assertRaises(ValueError):api.request('lookup',BASE+'/mp/getreviewid',{'urls':[self.url]})
    def test_default_offline_loads_no_account(self):
        with patch('verify_mp_resolve.SessionStore') as session,patch('verify_mp_resolve.NativeSessionStore') as native,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0);session.assert_not_called();native.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_ignores_dynamic_shell_but_checks_body_and_title(self):
        def page(title,body,nonce):
            return '<meta property="og:title" content="'+title+'"><script>var nonce="'+nonce+'"</script><div id="js_content">'+body+'</div><script></script>'
        self.assertTrue(same_article(page('Title','Hello','1'),page('Title','Hello','2')))
        self.assertFalse(same_article(page('Title','Hello','1'),page('Title','Changed','2')))
        self.assertFalse(same_article(page('Title','Hello','1'),page('Other','Hello','2')))


if __name__=='__main__':unittest.main()
