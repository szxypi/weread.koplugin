"""Exercise the full workflow with both real scoped transports and fake HTTP."""
from copy import deepcopy
import json
import unittest
from urllib.parse import urlsplit

from cloud_group_contract import digest, project
from cloud_group_fixture import Journal as UploadJournal, binding
from cloud_group_journal import Journal as OldJournal
from cloud_group_nonempty_journal import Journal as GroupJournal
from cloud_group_nonempty_transport import ScopedNative
from cloud_group_nonempty_workflow import execute
from cloud_group_old_guard import Guard
from cloud_group_upload_transport import GuardedUploadProbe
from synthetic_format_trial import TargetReceipt
from test_native_shelf_trial import source
from test_secure_native_session import Backend,credentials


class Response:
    status=200
    def __init__(self,value):self.value=value
    def __enter__(self):return self
    def __exit__(self,*_):return False
    def read(self,_):return self.value


class Service:
    def __init__(self,mode):
        self.mode=mode;self.shelf=source();self.shelf['albums']=[];self.shelf['archive'][0]['albumIds']=[];self.calls=[]
    def pair(self):return {'native':deepcopy(self.shelf),'web':deepcopy(self.shelf)}
    def open(self,request,timeout):
        path=urlsplit(request.full_url).path;self.calls.append(path)
        if path=='/shelf/sync': value=self.shelf
        elif path=='/cos/getcredential':
            value=dict(bucket='synthetic-12345',ObjectName='/prefix/synthetic-book',Response=dict(ExpiredTime=1300,
                Credentials=dict(TmpSecretId='synthetic-id',TmpSecretKey='synthetic-key',Token='synthetic-token')))
        elif path=='/prefix/synthetic-book':return Response(b'')
        elif path=='/cos/notify':
            self.shelf['books'].append(dict(bookId='CB_synthetic123',title='Fixture',finishReading=0))
            value={'status':1,'bookId':'CB_synthetic123'}
        elif path=='/shelf/archive':
            body=json.loads(request.data)
            if self.mode!='missing':self.shelf['archive'].append(dict(archiveId=43,name=body['name'],bookIds=body['bookIds'],albumIds=[]))
            if self.mode=='lost':raise TimeoutError()
            value={'succ':1}
        elif path=='/shelf/deleteArchive':
            body=json.loads(request.data)
            if body!={'archiveId':43,'removeBooks':0}:raise AssertionError()
            self.shelf['archive'].pop();value={'succ':1}
        elif path=='/shelf/delete':
            body=json.loads(request.data)
            if body!={'bookIds':['CB_synthetic123'],'albumIds':[],'archiveIds':[]}:raise AssertionError()
            self.shelf['books'].pop();value={'succ':1}
        else:raise AssertionError(path)
        return Response(json.dumps(deepcopy(value)).encode())


class FullTransportTest(unittest.TestCase):
    def run_case(self,mode):
        grant=credentials();service=Service(mode);initial=project(service.shelf)
        old=OldJournal(backend=Backend());token=old.begin(grant['vid'],digest(grant),'KOReader-Test-'+'a'*24,digest(initial),digest(initial))
        token=old.advance(token,'create_claimed');old.close_unchanged(token,[(initial,initial),(initial,initial)])
        uploads=UploadJournal(Backend());groups=GroupJournal(Backend());receipt=TargetReceipt('epub',backend=Backend(),scope='group-fixture')
        guard=Guard(old,None,grant,lambda:True,service.pair)
        native=ScopedNative(groups,lambda:binding(uploads,receipt.backend),grant,lambda:True,lambda:True,
                            lambda:bool(guard.check(False)),opener=service)
        probe=GuardedUploadProbe(uploads,lambda _:True,groups,receipt,guard.check,lambda:True,opener=service,cos_opener=service)
        result=execute(upload_probe=probe,upload_journal=uploads,group_journal=groups,target_receipt=receipt,
            grant=grant,current=lambda:True,old_guard=guard.check,read_pair=service.pair,post=native.post,pending=lambda:True,
            read_content=lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000)
        return result,service,uploads,groups

    def test_success_exact_requests_and_final_state(self):
        result,service,uploads,groups=self.run_case('ok')
        self.assertEqual(result['result'],'PASS');self.assertEqual(uploads.read()[0]['phase'],'restored')
        for path in ('/cos/getcredential','/prefix/synthetic-book','/cos/notify','/shelf/archive','/shelf/deleteArchive','/shelf/delete'):
            self.assertEqual(service.calls.count(path),1)
        self.assertEqual(groups.read()[0]['phase'],'restored')

    def test_unknown_group_stops_fixture_cleanup(self):
        for mode in ('missing','lost'):
            with self.subTest(mode=mode):
                result,service,uploads,groups=self.run_case(mode)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(service.calls.count('/shelf/archive'),1)
                self.assertNotIn('/shelf/deleteArchive',service.calls);self.assertNotIn('/shelf/delete',service.calls)
                self.assertEqual(uploads.read()[0]['phase'],'imported');self.assertEqual(groups.read()[0]['phase'],'create_claimed')


if __name__=='__main__':unittest.main()
