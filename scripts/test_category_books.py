"""Offline public list contracts, bounded transport and redacted UI proofs."""
import copy
import io
import json
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import verify_category_books as probe
import public_category_ui_contract as contract


def fixture():
    tree=probe.catalog(dict(data=[dict(CategoryId='rising',title='Rank'),
        dict(CategoryId='100000',title='Main',sublist=[dict(CategoryId='100001',title='Child')])]),1000)
    samples=[]
    for target in probe.targets(tree):
        expected=probe.page(dict(books=[dict(bookInfo=dict(bookId='900001',title='Synthetic',author='Author'))],hasMore=0))
        samples.append(dict(role=target['role'],entry=target['entry'],cursor=0,expected=expected))
    return dict(catalog=tree,samples=samples)


def envelope(payload):
    planned=[(row['role'],row['cursor']) for row in payload['samples']]
    reports=[];private=[]
    sources=[dict(role=row['role'],cursor=0,source=dict(books=[dict(bookInfo=row['expected']['books'][0])],hasMore=0)) for row in payload['samples']]
    for index,mode in enumerate(('live','reopen')):
        views=planned if index==0 else [planned[-1]]+planned
        report={key:True for key in contract.FLAGS}
        report.update({key:0 for key in contract.COUNTS})
        report.update(result='PASS',mode=mode,phase='complete',request_counts=[int(index==0)]*4,
                      batch_views=len(views),painted_views=len(views),forward_books=len(views),profile_files=3)
        reports.append(report)
        catalog_source=dict(data=[dict(CategoryId='rising',title='Rank'),dict(CategoryId='100000',title='Main',sublist=[dict(CategoryId='100001',title='Child')])])
        private.append(dict(catalog_source=catalog_source if index==0 else None,sources=sources if index==0 else [],
            views=[dict(role=role,cursor=cursor,cached=index==1,**payload['samples'][0]['expected']) for role,cursor in views]))
    report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,installed_bytes_match=True,installed_files=215,stages=reports,runner_error='none')
    return report,private


def encode(report,private):return contract.PRIVATE+json.dumps(private).encode()+contract.FRAME+json.dumps(report).encode()


class CategoryBooksTests(unittest.TestCase):
    def test_offline_without_network_or_child(self):
        with patch.object(probe,'Probe') as network,patch.object(probe.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(probe.main([]),0)
        network.assert_not_called();child.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_projection_nested_identity_and_whitelist(self):
        value=probe.page(dict(books=[dict(bookInfo=dict(book=dict(bookId='CB_900001',title='标题',private_extra='discard')),searchIdx=20),
                                    dict(bookInfo=dict(bookId='CB_900001',title='duplicate'),searchIdx=21)],hasMore=1))
        self.assertEqual((len(value['books']),value['next_cursor'],value['has_more']),(1,21,True))
        self.assertNotIn('private_extra',json.dumps(value));self.assertNotIn('session_id',value)

    def test_invalid_shapes_and_errors(self):
        for value in (None,[],{},dict(books={}),dict(books=[False]),dict(books=[],errCode=-1),dict(books=[],succ=False),dict(books=[{}]*101)):
            with self.subTest(value=value),self.assertRaises(ValueError):probe.page(value)

    def test_text_and_cursor_limits(self):
        for title in (False,'bad\nlabel','x'*4097):
            with self.assertRaises(ValueError):probe.page(dict(books=[dict(bookId='1',title=title)]))
        for cursor in (True,0.5,float('inf'),float('nan'),-1,'20',2**31):
            with self.subTest(cursor=cursor),self.assertRaises(ValueError):probe.page(dict(books=[dict(bookId='1',idx=cursor)]))

    def test_missing_nonadvancing_cursor_has_no_continuation(self):
        self.assertFalse(probe.page(dict(books=[dict(bookId='1')]*20),20)['has_more'])
        self.assertFalse(probe.page(dict(books=[],hasMore=True),0)['has_more'])

    def test_three_distinct_roles_and_safe_urls(self):
        payload=fixture();self.assertEqual([row['role'] for row in payload['samples']],['rank','main','child'])
        self.assertEqual(probe.url(payload['samples'][0]['entry'],20),'https://weread.qq.com/web/bookListInCategory/rising?rank=1&maxIndex=20')
        for identity in ('../bad','bad?token=x','x'*129):
            with self.assertRaises(ValueError):probe.url(dict(id=identity,rank=False),0)
        tree=copy.deepcopy(payload['catalog']);tree['categories'][0]['children'][0]['id']='100000'
        with self.assertRaises(ValueError):probe.targets(tree)

    def test_unapproved_request_never_reaches_opener(self):
        p=probe.Probe(opener=object())
        for address in ('https://weread.qq.com/web/shelf/sync','http://weread.qq.com/web/categories?rank=1&synckey=0',probe.CATALOG+'#fragment'):
            with self.assertRaises(ValueError):p.fetch('catalog',address)
        p.calls=7
        with self.assertRaises(ValueError):p.fetch('catalog',probe.CATALOG)

    def test_transport_headers_and_no_redirect(self):
        class Response:
            status=200;url=probe.CATALOG
            def __enter__(self):return self
            def __exit__(self,*_args):return False
            def read(self,limit):self.limit=limit;return b'{"data":[]}'
        class Opener:
            def open(self,request,timeout):self.request,self.timeout=request,timeout;return Response()
        opener=Opener();p=probe.Probe(opener=opener);self.assertEqual(p.fetch('catalog',probe.CATALOG),dict(data=[]))
        self.assertEqual(opener.request.get_method(),'GET');self.assertIsNone(opener.request.data)
        self.assertEqual(set(dict(opener.request.header_items())),{'User-agent','Accept','Referer'})
        self.assertIsNone(probe.NoRedirect().redirect_request(None,None,302,None,None,None))

    def test_response_limit(self):
        class Response:
            status=200;url=probe.CATALOG
            def __enter__(self):return self
            def __exit__(self,*_args):return False
            def read(self,limit):return b'x'*limit
        class Opener:
            def open(self,*_args,**_kwargs):return Response()
        with self.assertRaises(ValueError):probe.Probe(opener=Opener()).fetch('catalog',probe.CATALOG)

    def test_online_failure_redacts_details(self):
        with patch.object(probe.Probe,'prepare',side_effect=ValueError('private response body and query')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(probe.main(['--online']),1)
        self.assertNotIn('private response',out.getvalue());self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)

    def test_same_response_ui_and_offline_comparison(self):
        payload=fixture();report,private=envelope(payload)
        self.assertEqual(contract.compare_runner(encode(report,private),payload),report)
        private[1]['views'][0]['books'][0]['title']='changed'
        with self.assertRaises(ValueError):contract.compare_runner(encode(report,private),payload)

    def test_ui_report_rejects_extra_or_invalid_values(self):
        payload=fixture();report,private=envelope(payload)
        for change in ('extra','float','phase','requests','owner','install','removed','unverified_stage'):
            value=copy.deepcopy(report)
            if change=='extra':value['private_title']='forbidden'
            elif change=='float':value['stages'][0]['forward_books']=1.0
            elif change=='phase':value['stages'][0]['phase']='private title'
            elif change=='requests':value['stages'][1]['request_counts'][0]=1
            elif change=='owner':value['stages'][0]['guest']=False
            elif change=='install':value['installed_bytes_match']=False
            elif change=='removed':value['profile_removed']=False
            else:value['stages'][0]['result']='UNVERIFIED'
            with self.subTest(change=change),self.assertRaises(ValueError):contract.compare_runner(encode(value,private),payload)


if __name__=='__main__':unittest.main()
