"""Exercise upload, group effects, and cleanup as one simulated transaction."""
from copy import deepcopy
import unittest

from cloud_group_contract import project
from cloud_group_fixture import Journal as UploadJournal
from cloud_group_nonempty_inspect import inspect
from cloud_group_nonempty_journal import Journal as GroupJournal
from cloud_group_nonempty_workflow import execute
from synthetic_format_trial import TargetReceipt
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend, credentials


class Service(FakeProbe):
    def __init__(self, mode='ok'):
        super().__init__();self.mode=mode;self.state['albums']=[];self.state['archive'][0]['albumIds']=[]
        self.posts=[];self.baseline=project(self.state)
    def pair(self): return {'native':deepcopy(self.state),'web':deepcopy(self.state)}
    def guard(self, baseline):
        result=(project(self.state),project(self.state))
        if baseline and result[0]!=self.baseline: raise ValueError('changed')
        return result
    def group_post(self,journal,path,body):
        state,token=journal.read();journal.claim_dispatch(token,state['phase']);self.posts.append(path)
        if path=='/shelf/archive':
            if self.mode!='missing':
                self.state['archive'].append(dict(archiveId=43,name=body['name'],bookIds=body['bookIds'],albumIds=[]))
            if self.mode=='lost_create': raise TimeoutError()
        else:
            if self.mode!='lost_delete_before': self.state['archive'].pop()
            if self.mode=='lost_delete': raise TimeoutError()
        return {'succ':1}


class WorkflowTest(unittest.TestCase):
    def setup_flow(self, mode='ok'):
        service=Service(mode);upload=UploadJournal(Backend());group=GroupJournal(Backend())
        target=TargetReceipt('epub',backend=Backend(),scope='group-fixture')
        opts=dict(upload_probe=service,upload_journal=upload,group_journal=group,target_receipt=target,
            grant=credentials(),current=lambda:True,old_guard=service.guard,read_pair=service.pair,
            post=lambda path,body:service.group_post(group,path,body),pending=lambda:True,read_content=lambda _:True,
            apply=True,sleep=lambda _:None,now=lambda:1000)
        return service,upload,group,target,opts

    def test_full_roundtrip_and_permanent_no_replay(self):
        service,upload,group,target,opts=self.setup_flow();result=execute(**opts)
        self.assertEqual(result['result'],'PASS');self.assertTrue(result['full_shelf_restored'])
        self.assertEqual(service.posts,['/shelf/archive','/shelf/deleteArchive'])
        self.assertEqual(service.attempts['cleanup'],1);self.assertEqual(upload.read()[0]['phase'],'restored')
        self.assertEqual(group.read()[0]['phase'],'restored')
        self.assertEqual(execute(**opts)['result'],'UNVERIFIED');self.assertEqual(service.attempts['cleanup'],1)

    def test_uncertainty_keeps_fixture_and_stops_following_writes(self):
        for mode,posts in (('missing',1),('lost_create',1),('lost_delete',2)):
            with self.subTest(mode=mode):
                service,upload,group,target,opts=self.setup_flow(mode);result=execute(**opts)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(len(service.posts),posts)
                self.assertEqual(service.attempts['cleanup'],0);self.assertEqual(upload.read()[0]['phase'],'imported')
                self.assertEqual(execute(**opts)['result'],'UNVERIFIED');self.assertEqual(len(service.posts),posts)
                from cloud_group_fixture import binding
                observed=inspect(group,lambda:binding(upload,target.backend),opts['grant'],opts['current'],service.pair)
                self.assertEqual(observed['result'],'INSPECTED');self.assertEqual(observed['data_posts'],0)
                self.assertTrue(observed['native_fixture_present'] and observed['web_fixture_present'])

    def test_stale_or_inconsistent_readback_blocks_cleanup(self):
        service,upload,group,target,opts=self.setup_flow();pair=service.pair
        def changed():
            value=pair()
            if len(service.posts)==2: value['web']['books'][0]['secret']=1
            return value
        opts['read_pair']=changed;result=execute(**opts)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(service.attempts['cleanup'],0)
        self.assertEqual(upload.read()[0]['phase'],'imported')

    def test_preview_and_pending_scope_do_not_write(self):
        service,upload,group,target,opts=self.setup_flow();opts['apply']=False
        self.assertEqual(execute(**opts)['result'],'READ_ONLY_PREVIEW');self.assertFalse(any(service.attempts.values()))
        self.assertIsNone(group.read()[0]);self.assertIsNone(upload.read()[0])
        opts.update(apply=True,pending=lambda:False)
        self.assertEqual(execute(**opts)['result'],'UNVERIFIED');self.assertFalse(any(service.attempts.values()))


if __name__=='__main__':unittest.main()
