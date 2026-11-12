"""Offline owner bookstore UI opt-in and metadata-only receipt boundaries."""
from contextlib import redirect_stdout,redirect_stderr
import io
import json
import subprocess
import unittest
from copy import deepcopy
from unittest.mock import patch
from verify_owner_discovery import FLAGS,FRAME,PRIVATE_FRAME,decode_runner,decode_stage,main,stage,compare_private,page


def receipt(mode='live'):
    return dict(result='PASS',mode=mode,phase='complete',worker_http_child=mode=='live',validated_views=5 if mode=='live' else 8,
        samples=5,profile_files_audited=7,screenshots=0,forbidden_requests=0,failed_line=0,batch_sizes=[20,2,20,3,0],
        request_counts=[1]*5 if mode=='live' else [0]*5,**dict.fromkeys(FLAGS,True))


def outer():return dict(result='PASS',tmpfs_profile=True,profile_removed=True,installed_bytes_match=True,installed_files=203,stages=[receipt(),receipt('reopen')],runner_error='none')


def private_fixture():
    sources=[];views=[];plans=[]
    for kind,cursor,count,more in [('search',0,20,True),('search',20,2,False),('similar',0,20,True),('similar',20,3,False),('recommend',0,0,False)]:
        rows=[dict(bookId=str((1 if kind=='search' else 2)*100000+cursor+i+1),title='Synthetic',searchIdx=cursor+i+1) for i in range(count)]
        raw=dict(books=rows,hasMore=more)
        if kind=='similar':raw=dict(booksimilar=dict(raw,sessionId='synthetic-session'))
        model=page(kind,raw,cursor);plans.append(dict(kind=kind,cursor=cursor,expected=model))
        sources.append(dict(kind=kind,cursor=cursor,source=raw))
        views.append(dict(kind=kind,cursor=cursor,books=model['books'],has_more=more,next_cursor=model['next_cursor'],cached=False))
    offline=[dict(views[-1],cached=True)]
    for view in views:
        offline.append(dict(view,cached=True))
        if view['cursor']:offline.append(dict(next(row for row in views if row['kind']==view['kind'] and not row['cursor']),cached=True))
    return [dict(sources=sources,views=views),dict(sources=[],views=offline)],plans


class Tests(unittest.TestCase):
    def test_valid_two_process_receipt(self):
        self.assertEqual(decode_runner(FRAME+json.dumps(outer()).encode()),outer())
        self.assertEqual(decode_stage(FRAME+json.dumps(receipt()).encode(),'live'),receipt())

    def test_each_acceptance_gate_required(self):
        for key in FLAGS:
            value=receipt();value[key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):stage(value,'live')

    def test_private_and_invalid_fields_rejected(self):
        for key,bad in [('titles','private'),('credentials',{}),('phase',[]),('samples',True),('screenshots',1),
                        ('batch_sizes',[101]*5),('request_counts',[True]*5),('request_counts',[1]*7),('validated_views',4)]:
            value=receipt();value[key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):stage(value,'live')

    def test_offline_network_and_unclean_runner_rejected(self):
        value=receipt('reopen');value['request_counts'][0]=1
        with self.assertRaises(ValueError):stage(value,'reopen')
        for key,bad in [('profile_removed',False),('tmpfs_profile',False),('installed_bytes_match',False),('installed_files',0),('stages',[receipt()]),('runner_error',[])]:
            value=outer();value[key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):decode_runner(FRAME+json.dumps(value).encode())
        value=outer();value['stages'][1]['batch_sizes'][0]=19
        with self.assertRaises(ValueError):decode_runner(FRAME+json.dumps(value).encode())

    def test_frames_bounded_and_unique(self):
        for raw in [b'private',FRAME+b'{}'+FRAME+b'{}',b'x'*65537]:
            with self.assertRaises(ValueError):decode_runner(raw)

    def test_offline_default_and_invalid_args_do_not_load_credentials(self):
        with patch('verify_owner_discovery.SessionStore') as saved,redirect_stdout(io.StringIO()) as out:self.assertEqual(main([]),0)
        saved.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        for args in [['--saved-session'],['--lua-command','invalid']]:
            with patch('verify_owner_discovery.SessionStore') as saved,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)
            saved.assert_not_called()

    def invoke(self,response,code=0):
        grant=dict(vid='900000',accessToken='private-token');private,plans=private_fixture();payload=dict(credentials=grant,samples=plans)
        with patch('verify_owner_discovery.SessionStore') as web,patch('verify_owner_discovery.NativeSessionStore') as native,\
             patch('verify_owner_discovery.DiscoveryProbe') as probe,patch('verify_owner_discovery.prepare',return_value=(payload,{})),\
             patch('verify_owner_discovery.subprocess.run') as child,redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='900000');native.return_value.load.return_value=grant;probe.return_value.report=dict(stages=[])
            if isinstance(response,Exception):child.side_effect=response
            else:child.return_value=subprocess.CompletedProcess([],code,PRIVATE_FRAME+json.dumps(private).encode()+FRAME+json.dumps(response).encode(),b'private stderr')
            result=main(['--saved-session','--lua-command','controlled'])
        self.assertEqual(grant,{})
        for secret in ['private-token','private stderr','"900000"']:self.assertNotIn(secret,out.getvalue())
        native.return_value.delete.assert_not_called();web.return_value.delete.assert_not_called()
        return result,json.loads(out.getvalue())

    def test_same_wire_projection_and_saved_views_match(self):
        private,plans=private_fixture();self.assertTrue(compare_private(private,plans))
        private[0]['views'][2]['books'][0]['title']='Wrong projection'
        with self.assertRaises(ValueError):compare_private(private,plans)

    def test_missing_reordered_or_changed_offline_views_fail(self):
        for change in ['missing','order','book','request']:
            private,plans=private_fixture()
            if change=='missing':private[1]['views'].pop()
            elif change=='order':private[1]['views'].reverse()
            elif change=='book':private[1]['views'][1]=deepcopy(private[1]['views'][1]);private[1]['views'][1]['books'][0]['title']='Changed'
            else:private[1]['sources']=private[0]['sources']
            with self.subTest(change=change),self.assertRaises(ValueError):compare_private(private,plans)

    def test_unverified_partial_stage_preserves_only_debug_metadata(self):
        value=receipt();value.update(result='UNVERIFIED',phase='similar',validated_views=2,samples=0,batch_sizes=[20,2],request_counts=[1,1,1,0,0],failed_line=145)
        self.assertEqual(stage(value,'live')['failed_line'],145)

    def test_success_is_redacted(self):
        result,value=self.invoke(outer());self.assertEqual(result,0);self.assertEqual(value['result'],'OWNER_DISCOVERY_FILE_UI_AND_OFFLINE_VERIFIED')

    def test_timeout_or_bad_child_cannot_pass_or_leak(self):
        for response in [dict(outer(),credentials='private'),subprocess.TimeoutExpired('private',320)]:
            result,value=self.invoke(response);self.assertEqual(result,1);self.assertEqual(value['result'],'UNVERIFIED')
        self.assertEqual(self.invoke(outer(),code=1)[0],1)


if __name__=='__main__':unittest.main()
