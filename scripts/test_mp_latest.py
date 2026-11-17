"""Offline public-account latest-article proof boundaries."""
import contextlib,io,json,unittest
from unittest.mock import patch
from verify_mp_latest import Probe,main,project
from verify_web_source_progress import BASE

ACCOUNT='MP_WXS_42';REVIEW=ACCOUNT+'_synthetic_1'


class LatestTest(unittest.TestCase):
    def test_exact_owner_identity_and_display_projection(self):
        value=project(dict(reviewId=REVIEW,title='Synthetic',private='discard'),ACCOUNT)
        self.assertEqual(value,dict(reviewId=REVIEW,title='Synthetic',bookId=ACCOUNT))
        for raw in ({},{'reviewId':'MP_WXS_43_bad','title':'Wrong owner'}, {'reviewId':ACCOUNT+'_','title':'Empty'},
                    {'reviewId':REVIEW,'title':''},{'reviewId':REVIEW,'title':'bad\nvalue'},
                    {'reviewId':REVIEW,'title':'Valid','errCode':-2041}, {'reviewId':REVIEW,'title':'Valid','errcode':False}):
            with self.subTest(raw=raw),self.assertRaises(ValueError):project(raw,ACCOUNT)

    def test_request_guard_is_exact_authenticated_and_once_only(self):
        probe=Probe();probe.vid='900000';url=BASE+'/api/mp/cover?bookId='+ACCOUNT;probe.allowed['cover']=url
        with self.assertRaises(Exception):probe.guard('cover',url,None)
        probe.authenticated=True
        for stage,target,body in [('cover',url+'1',None),('cover','https://evil.invalid/',None),('cover',url,{})]:
            with self.assertRaises(Exception):probe.guard(stage,target,body)
        probe.guard('cover',url,None);self.assertEqual(probe.sent['cover'],1)
        with self.assertRaises(Exception):probe.guard('cover',url,None)
        probe.close()

    def test_default_is_offline_and_does_not_load_credentials(self):
        with patch('verify_mp_latest.SessionStore') as session,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0);session.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(['--lua-command','synthetic'])


if __name__=='__main__':unittest.main()
