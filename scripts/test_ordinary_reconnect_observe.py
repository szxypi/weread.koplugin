import copy
import hashlib
import unittest
from unittest.mock import patch

import ordinary_reconnect_observe as subject
from shelf_flag_change_contract import state_hash
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

    def test_entered_position_retains_original_percent(self):
        entered=subject.entered_point(self.plan)
        self.web.point=copy.deepcopy(entered);self.native.point=copy.deepcopy(entered)
        self.assertTrue(subject.check(self.web,self.native,self.grant,self.plan,entered,lambda:True))
        with self.assertRaisesRegex(ValueError,'ordinary_trial/web_position'):
            subject.check(self.web,self.native,self.grant,self.plan,self.plan['target'],lambda:True)

    def test_position_can_preserve_only_original_percent_when_both_services_agree(self):
        entered=subject.entered_point(self.plan);target=self.plan['target']
        self.assertNotEqual(entered['raw_percent'],target['raw_percent'])
        self.web.point=copy.deepcopy(entered);self.native.point=copy.deepcopy(entered);diagnostic={}
        self.assertTrue(subject.check(self.web,self.native,self.grant,self.plan,target,lambda:True,
                                      allow_preserved_percent=True,diagnostic=diagnostic))
        self.assertEqual(diagnostic,{'percent_mode':'preserved'})
        self.native.point=copy.deepcopy(target)
        with self.assertRaises(ValueError):subject.check(self.web,self.native,self.grant,self.plan,target,lambda:True,allow_preserved_percent=True)
        self.native.point=copy.deepcopy(entered);self.web.point['summary']='unrelated'
        with self.assertRaisesRegex(ValueError,'ordinary_trial/web_summary'):
            subject.check(self.web,self.native,self.grant,self.plan,target,lambda:True,allow_preserved_percent=True)
        self.web.point=copy.deepcopy(entered)
        self.web.point['raw_percent']=min(100,max(0,entered['raw_percent']+1))
        if self.web.point['raw_percent']==target['raw_percent']:self.web.point['raw_percent']=(target['raw_percent']+1)%101
        self.native.point=copy.deepcopy(self.web.point)
        with self.assertRaises(ValueError):subject.check(self.web,self.native,self.grant,self.plan,target,lambda:True,allow_preserved_percent=True)
        with self.assertRaises(ValueError):subject.check(self.web,self.native,self.grant,self.plan,self.plan['baseline'],lambda:True,allow_preserved_percent=True)
        self.web.point=copy.deepcopy(target);self.native.point=copy.deepcopy(target);diagnostic={}
        self.assertTrue(subject.check(self.web,self.native,self.grant,self.plan,target,lambda:True,allow_preserved_percent=True,diagnostic=diagnostic))
        self.assertEqual(diagnostic,{'percent_mode':'target'})

    def test_only_target_recent_time_and_target_position_may_change(self):
        first={'books':[{'bookId':'900001','readUpdateTime':10,'title':'target'},
                        {'bookId':'900002','readUpdateTime':1,'title':'other'},
                        {'bookId':'900003','readUpdateTime':2,'title':'other2'}], 'lectureSynckey':100}
        later=copy.deepcopy(first);later['lectureSynckey']=101
        target=later['books'].pop(0);target['readUpdateTime']=11;later['books'].append(target)
        self.assertTrue(subject.scoped_shelf_equal(first,later,'900001'))
        altered=copy.deepcopy(later);altered['books'][0]['title']='different'
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001'))
        altered=copy.deepcopy(later);altered['books'][-1]['title']='different'
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001'))
        altered=copy.deepcopy(later);altered['books'][0],altered['books'][1]=altered['books'][1],altered['books'][0]
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001'))
        altered=copy.deepcopy(later);altered['books'][-1]['readUpdateTime']=9
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001'))
        altered=copy.deepcopy(later);altered['books'][-1]['readUpdateTime']=True
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001'))
        altered=copy.deepcopy(later);del altered['books'][-1]['readUpdateTime']
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001'))
        altered=copy.deepcopy(later);altered['books'].append(copy.deepcopy(altered['books'][-1]))
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001'))
        altered=copy.deepcopy(later);altered['lectureSynckey']=99
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001'))

    def test_observer_binds_original_shelf_before_allowing_target_read_time(self):
        self.shelf['books'][0]['readUpdateTime']=10
        self.plan['web_shelf_sha256']=digest({'books':[{'bookId':'900001','readUpdateTime':10}]})
        self.plan['native_shelf_sha256']=self.plan['web_shelf_sha256']
        snapshots=subject.capture_shelves(self.web,self.native,self.grant,self.plan,lambda:True)
        self.shelf['books'][0]['readUpdateTime']=11
        self.assertTrue(subject.check(self.web,self.native,self.grant,self.plan,self.plan['baseline'],lambda:True,shelf_baselines=snapshots))
        self.shelf['books'][0]['title']='changed'
        with self.assertRaisesRegex(ValueError,'ordinary_trial/shelf'):
            subject.check(self.web,self.native,self.grant,self.plan,self.plan['baseline'],lambda:True,shelf_baselines=snapshots)

    def test_fresh_process_can_verify_core_without_claiming_full_shelf_equality(self):
        self.plan.update(web_shelf_core_sha256=state_hash(self.shelf),native_shelf_core_sha256=state_hash(self.shelf))
        self.shelf['books'][0]['readUpdateTime']=11
        self.assertTrue(subject.check(self.web,self.native,self.grant,self.plan,self.plan['baseline'],lambda:True,shelf_core_only=True))
        self.shelf['books'][0]['secret']=1
        with self.assertRaisesRegex(ValueError,'ordinary_trial/shelf'):
            subject.check(self.web,self.native,self.grant,self.plan,self.plan['baseline'],lambda:True,shelf_core_only=True)

    def test_target_shelf_progress_must_match_exact_expected_state(self):
        from fetch_weread_epub import web_app_id
        first={'books':[{'bookId':'900001','readUpdateTime':10}], 'bookProgress':[
            {'bookId':'900001','chapterUid':123,'chapterIdx':3,'chapterOffset':100,'progress':12,'appId':'old',
             'updateTime':10,'synckey':10,'readingTime':20},
            {'bookId':'900002','progress':33}], 'lectureSynckey':100,'synckey':100}
        later=copy.deepcopy(first);later['lectureSynckey']=101;later['synckey']=101;later['books'][0]['readUpdateTime']=11
        entry=later['bookProgress'].pop(0);entry.update(chapterOffset=300,appId=web_app_id(),updateTime=11,synckey=11)
        later['bookProgress'].append(entry);expected=subject.entered_point(self.plan)
        self.assertTrue(subject.scoped_shelf_equal(first,later,'900001',expected))
        for field,value in [('chapterOffset',301),('progress',13),('readingTime',21),('appId','unknown'),('synckey',9)]:
            altered=copy.deepcopy(later);altered['bookProgress'][-1][field]=value
            with self.subTest(field=field):self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001',expected))
        altered=copy.deepcopy(later);altered['bookProgress'][0]['progress']=34
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001',expected))
        altered=copy.deepcopy(later);altered['synckey']=99
        self.assertFalse(subject.scoped_shelf_equal(first,altered,'900001',expected))


if __name__=='__main__':unittest.main()
