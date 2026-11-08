"""No network or real Keychain access. Catalog reads and renewal boundaries."""
from contextlib import redirect_stdout
import io,json,unittest
from unittest.mock import patch
from secure_weread_session import SessionStore,StoreError
from test_secure_weread_session import Backend,probe
from verify_web_source_progress import BASE
import verify_mp_catalog as mp


class Response:
    status=200
    headers={}
    def __init__(self,value):self.value=json.dumps(value).encode()
    def read(self,_limit):return self.value
    def __enter__(self):return self
    def __exit__(self,*_args):return False


class MPCatalogTests(unittest.TestCase):
    def fixture(self):
        backend=Backend();store=SessionStore(backend);value=probe();store.save(value)
        current=mp.MPProbe();current.vid=value.vid;current.authenticated=True;current.mp_book='MP_WXS_900001'
        for cookie in value.cookies:current.set_cookie(cookie.name,cookie.value)
        current.verify_account=lambda:None
        return store,current

    def test_default_no_store_or_network(self):
        with patch.object(mp,'SessionStore',side_effect=AssertionError('keychain')),patch.object(mp,'MPProbe',side_effect=AssertionError('network')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(mp.main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_guard_rejects_unrelated_routes_and_bodies(self):
        _,current=self.fixture()
        for stage,url,body in [('mp_catalog','https://evil.test/web/mp/articles',None),
                               ('mp_catalog',BASE+'/web/mp/articles?bookId=MP_WXS_900002&maxIdx=0&count=100',None),
                               ('web_renewal',BASE+'/web/login/renewal',{}),
                               ('mp_catalog',BASE+'/web/mp/articles?bookId=MP_WXS_900001&maxIdx=0&count=100&extra=1',None)]:
            with self.assertRaises(Exception):current.guard(stage,url,body)

    def test_one_renewal_saved_after_account_check(self):
        store,current=self.fixture();calls=[]
        class Opener:
            def open(self,request,**_kwargs):
                calls.append(request)
                response=Response({'succ':1});response.headers={'x-wr-ticket':'synthetic-mp-ticket'}
                return response
        current.opener=Opener()
        current.verify_account=lambda:self.assertTrue(store.load()['web']['renewal_pending'])
        saved=current.renew(store,store.load())
        self.assertEqual(len(calls),1)
        self.assertEqual(json.loads(calls[0].data),{'rq':'%2Fweb%2Fbook%2Fread','ql':False})
        self.assertFalse(saved['web']['renewal_pending'])
        self.assertEqual(saved['web']['headers']['wr_ticket'],'synthetic-mp-ticket')
        with self.assertRaises(mp.MPError):current.renew(store,saved)
        self.assertEqual(len(calls),1)

    def test_unknown_receipt_stays_pending_and_cannot_repeat(self):
        store,current=self.fixture();calls=[]
        class Opener:
            def open(self,*args,**_kwargs):calls.append(args);raise TimeoutError()
        current.opener=Opener()
        with self.assertRaises(mp.MPError):current.renew(store,store.load())
        self.assertTrue(store.load()['web']['renewal_pending'])
        replacement=mp.MPProbe();replacement.authenticated=True
        with self.assertRaises(StoreError):replacement.renew(store,store.load())
        self.assertEqual(len(calls),1)

    def test_no_headers_is_not_an_mp_grant(self):
        store,current=self.fixture()
        class Opener:
            def open(self,*_args,**_kwargs):return Response({'succ':1})
        current.opener=Opener()
        saved=current.renew(store,store.load())
        self.assertEqual(saved['web']['headers'],{})
        self.assertFalse(saved['web']['renewal_pending'])

    def test_catalog_request_has_only_captured_headers(self):
        _,current=self.fixture();calls=[]
        current.web_headers={'wr_ticket':'synthetic-mp-ticket','wr_wrpa':'synthetic-mp-protection'}
        class Opener:
            def open(self,request,**_kwargs):calls.append(request);return Response({'errCode':-2041})
        current.opener=Opener()
        self.assertEqual(current.catalog()['errCode'],-2041)
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0].get_method(),'GET')
        self.assertEqual(calls[0].get_header('X-wr-ticket'),'synthetic-mp-ticket')
        self.assertIsNone(calls[0].get_header('Authorization'))

    def test_existing_body_extraction_projection_is_bounded(self):
        body='<p>合成正文</p><img data-src="https://example.invalid/a" src=""/>'
        html='<div id="js_content">'+body+'</div><script>not copied</script>'
        import hashlib
        expected=body.replace('data-src=','src=').replace(' src=""','')
        self.assertEqual(mp.article_projection(html),dict(body_bytes=len(expected.encode()),body_sha256=hashlib.sha256(expected.encode()).hexdigest()))
        for invalid in ('<p>not an article</p>','x'*(4*1024*1024+1)):
            with self.assertRaises(mp.MPError):mp.article_projection(invalid)

    def test_shape_only_exports_static_field_names(self):
        self.assertEqual(mp.shape({'title':'private','12345678':'private','bad key':'private'}),{'title':'str'})


if __name__=='__main__':unittest.main()
