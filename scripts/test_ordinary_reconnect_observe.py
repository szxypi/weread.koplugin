import copy
import hashlib
import unittest
from unittest.mock import patch

import ordinary_reconnect_observe as subject
from test_secure_ordinary_reconnect_trial import plan
from txt_full_summary import digest


class Web:
    def __init__(self, point, shelf):
        self.vid='900000';self.book_id=point['book_id'];self.catalog={'catalog':'synthetic'}
        self.shards={'e_0':'a','e_1':'b','e_3':'c'};self.report={'read_snapshot_consistent':True}
        self.point=copy.deepcopy(point);self.shelf=shelf
    @property
    def raw_progress(self):
        p=self.point
        return {'book':dict(bookId=p['book_id'],chapterUid=p['chapter_uid'],chapterIdx=p['chapter_idx'],
                            chapterOffset=p['chapter_offset'],progress=p['raw_percent'],summary=p['summary'])}
    def verify_account(self): pass
    def inspect(self,identity): self.book_id=identity
    def request(self,stage,url):
        if stage!='shelf':raise ValueError('unexpected')
        return copy.deepcopy(self.shelf)


class Native:
    def __init__(self,point,counts,shelf):self.point=copy.deepcopy(point);self.counts=copy.deepcopy(counts);self.shelf=shelf;self.version=0
    def request(self,stage,url,credentials=None):
        if stage=='ordinary_rpc_progress':
            p=self.point
            return {'book':dict(bookId=p['book_id'],chapterUid=p['chapter_uid'],chapterIdx=p['chapter_idx'],
                                chapterOffset=p['chapter_offset'],progress=p['raw_percent'],summary=p['summary'],**self.counts)}
        if stage=='ordinary_rpc_info':return {'bookId':self.point['book_id'],'version':self.version}
        if stage=='ordinary_rpc_shelf':return copy.deepcopy(self.shelf)
        raise ValueError('unexpected')


class ObserveTests(unittest.TestCase):
    def setUp(self):
        self.plan=plan();self.grant={'synthetic':'grant'};self.shelf={'books':[{'bookId':'900001'}],'lectureSynckey':123}
        self.plan.update(owner_sha256=digest('900000'),grant_sha256=digest(self.grant),
                         source_sha256=hashlib.sha256(b'synthetic source').hexdigest(),
                         catalog_sha256=digest({'catalog':'synthetic'}),
                         web_shelf_sha256=digest({'books':[{'bookId':'900001'}]}),
                         native_shelf_sha256=digest({'books':[{'bookId':'900001'}]}))
        self.web=Web(self.plan['baseline'],self.shelf);self.native=Native(self.plan['baseline'],self.plan['counts'],self.shelf)
        self.decoder=patch.object(subject,'decode_content_shards',return_value='synthetic source');self.decoder.start();self.addCleanup(self.decoder.stop)
    def check(self):return subject.check(self.web,self.native,self.grant,self.plan,self.plan['baseline'],lambda:True)

    def test_independent_matching_snapshots_and_cursor_advance(self):
        self.assertTrue(self.check())
        self.web.shelf['lectureSynckey']+=1
        self.assertTrue(self.check())

    def test_rejects_changed_position_summary_source_catalog_shelf_or_counts(self):
        changes=[lambda:self.web.point.update(chapter_offset=101),lambda:self.web.point.update(summary='changed'),
                 lambda:self.native.point.update(raw_percent=20),lambda:self.native.counts.update(readingTime=1),
                 lambda:self.web.catalog.update(catalog='changed'),lambda:self.web.shelf.update(extra='changed'),
                 lambda:self.web.report.update(read_snapshot_consistent=False),lambda:setattr(self.native,'version',2)]
        for change in changes:
            with self.subTest(change=change):
                self.setUp();change()
                with self.assertRaises(ValueError):self.check()

    def test_credential_or_account_change_stops_before_reading(self):
        calls=[]
        with self.assertRaises(ValueError):subject.check(self.web,self.native,{'synthetic':'foreign'},self.plan,self.plan['baseline'],lambda:calls.append(1) or True)
        with self.assertRaises(ValueError):subject.check(self.web,self.native,self.grant,self.plan,self.plan['baseline'],lambda:False)
        self.assertEqual(len(calls),1)

    def test_source_bytes_checked_independently(self):
        with patch.object(subject,'decode_content_shards',return_value='different'):
            with self.assertRaisesRegex(ValueError,'ordinary_trial/source'):self.check()


if __name__=='__main__':unittest.main()
