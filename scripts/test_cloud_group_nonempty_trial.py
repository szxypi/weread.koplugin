"""Simulated service exercises bounded sends and uncertainty handling."""
from copy import deepcopy
import unittest

from cloud_group_fixture import Journal as UploadJournal, binding
from cloud_group_nonempty_journal import Journal
from cloud_group_nonempty_trial import Trial
from synthetic_format_trial import TargetReceipt
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend, credentials
from verify_synthetic_epub_upload import run as upload


class Service:
    def __init__(self, mode='ok'):
        self.mode=mode; self.posts=[]; self.reads=0
        self.shelf={'books':[{'bookId':'42','title':'Existing','finishReading':0},
                             {'bookId':'CB_synthetic123','title':'Fixture','finishReading':0}],
                    'archive':[{'archiveId':2,'name':'Existing','bookIds':['42','CB_synthetic123'],'albumIds':[]}], 'albums':[]}
    def read(self):
        self.reads+=1
        if self.mode=='foreign' and len(self.posts)==1: self.shelf['books'][0]['finishReading']=1
        native=deepcopy(self.shelf); web=deepcopy(self.shelf)
        if self.mode=='lag' and len(self.posts)==1: web['archive']=web['archive'][:1]
        return {'native':native,'web':web}
    def post(self, path, body):
        self.posts.append(path)
        if path=='/shelf/archive':
            if self.mode!='missing':
                self.shelf['archive'][0]['bookIds'].remove(body['bookIds'][0])
                self.shelf['archive'].append(dict(archiveId=43,name=body['name'],bookIds=body['bookIds'],albumIds=[]))
            if self.mode=='lost_create': raise TimeoutError()
        elif path=='/shelf/deleteArchive':
            if body!={'archiveId':43,'removeBooks':0}: raise AssertionError()
            self.shelf['archive'].pop()
            if self.mode=='lost_delete': raise TimeoutError()
        else: raise AssertionError()
        return {'succ':1}


def fixture():
    journal=UploadJournal(Backend()); store=Backend()
    receipt=TargetReceipt('epub', backend=store, scope='group-fixture')
    upload(FakeProbe(), journal, credentials(), lambda _:True, lambda _:True, apply=True, sleep=lambda _:None,
           now=lambda:1000, notify_receipt=receipt.record, cleanup_gate=lambda *_:False)
    return lambda:binding(journal,store)


class TrialTest(unittest.TestCase):
    def trial(self, service, journal):
        def post(path, body):
            _,token=journal.read()
            journal.claim_dispatch(token,'create_claimed' if path=='/shelf/archive' else 'delete_claimed')
            return service.post(path,body)
        return Trial(journal,fixture(),service.read,post,lambda:True,sleep=lambda _:None)

    def test_roundtrip_sends_once_and_cannot_replay(self):
        service=Service();journal=Journal(Backend());trial=self.trial(service,journal)
        report=trial.run();self.assertEqual(report['result'],'PASS');self.assertTrue(report['restored'])
        self.assertEqual(service.posts,['/shelf/archive','/shelf/deleteArchive']);self.assertEqual(journal.read()[0]['phase'],'restored')
        self.assertEqual(trial.run()['phase'],'scope_consumed');self.assertEqual(len(service.posts),2)

    def test_ambiguous_or_unrelated_change_stops_without_retry(self):
        for mode, count, phase in (('missing',1,'create_claimed'),('lag',1,'create_claimed'),
                                   ('lost_create',1,'create_claimed'),('foreign',1,'create_claimed'),
                                   ('lost_delete',2,'delete_claimed')):
            with self.subTest(mode=mode):
                service=Service(mode);journal=Journal(Backend());trial=self.trial(service,journal)
                self.assertEqual(trial.run()['result'],'UNVERIFIED');self.assertEqual(len(service.posts),count)
                self.assertEqual(journal.read()[0]['phase'],phase)
                self.assertEqual(trial.run()['phase'],'scope_consumed');self.assertEqual(len(service.posts),count)

    def test_stale_binding_or_hidden_albums_never_sends(self):
        service=Service();service.shelf.pop('albums');journal=Journal(Backend())
        report=Trial(journal,fixture(),service.read,service.post,lambda:True,sleep=lambda _:None).run()
        self.assertEqual(report['result'],'UNVERIFIED');self.assertFalse(service.posts);self.assertIsNone(journal.read()[0])
        service=Service();journal=Journal(Backend())
        report=Trial(journal,fixture(),service.read,service.post,lambda:False,sleep=lambda _:None).run()
        self.assertEqual(report['result'],'UNVERIFIED');self.assertFalse(service.posts);self.assertIsNone(journal.read()[0])


if __name__=='__main__':unittest.main()
