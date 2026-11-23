import hashlib
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from bookmark_point import first_position,project
from native_direct_cross_bookmark_trial import FRAME,prepare_origin,verify


class CrossBookmarkTrialTests(unittest.TestCase):
    def setUp(self):
        self.raw='<html><body><p>Unique synthetic bookmark source with a long enough preview.</p></body></html>'
        first=first_position(self.raw);point=project(self.raw,first)
        self.row=dict(bookmarkId='new-bookmark',chapterUid=37,type=0,range=point['range'],markText=point['markText'])
        self.target=dict(id='new-bookmark',sha256='a'*64)
        self.source=dict(book_id='42',uid='37',book_version=1,source=self.raw.encode(),
            source_sha256=hashlib.sha256(self.raw.encode()).hexdigest())
        self.origin=dict(book_id='42',uid='37',book_version=1,source_sha256=self.source['source_sha256'],
            origin_uid='38',origin_source_sha256='b'*64)
        self.snapshot={'marks':{'updated':{'new-bookmark':self.row}}}
        self.probe=SimpleNamespace(raw=self.raw,first=first,source=SimpleNamespace(payload={'cookies':{'wr_vid':'12345678'}}),
            read=lambda _credentials:(self.target,self.snapshot))
        self.calls=[]

    def runner(self,command,**kwargs):
        self.calls.append(command)
        payload=json.loads(kwargs['input']);self.assertEqual(payload['expected_id'],'new-bookmark')
        self.assertEqual(payload['origin_uid'],'38');self.assertTrue(payload['expect_bookmarks'])
        row=dict(id='new-bookmark',range=self.row['range'],text=self.row['markText'])
        result=dict(result='PASS',rows=[row],offline_reopen=True,credential_file_audit=True,installed_bytes_match=True,
            profile_removed=True,navigation=True,indicator=True)
        return SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(result).encode()+b'\n')

    def test_both_sizes_and_independent_point_are_required(self):
        result=verify(self.probe,{},self.source,self.origin,self.target,['runner'],run=self.runner)
        self.assertEqual(result['screens'],2);self.assertTrue(result['indicator_tap_verified']);self.assertEqual(len(self.calls),2)
        self.assertEqual(self.calls[0][-6:],['--width','600','--height','800','--dpi','167'])
        self.assertEqual(self.calls[1][-6:],['--width','1264','--height','1680','--dpi','300'])

    def test_indicator_proof_is_required(self):
        def without_indicator(command,**kwargs):
            result=self.runner(command,**kwargs)
            value=json.loads(result.stdout.split(FRAME,1)[1]);value.pop('indicator')
            return SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(value).encode()+b'\n')
        with self.assertRaises(ValueError):verify(self.probe,{},self.source,self.origin,self.target,['runner'],run=without_indicator)

    def test_bad_point_changed_source_or_changed_snapshot_is_rejected(self):
        self.row['range']='0'
        with self.assertRaises(ValueError):verify(self.probe,{},self.source,self.origin,self.target,['runner'],run=self.runner)
        self.row['range']=project(self.raw,self.probe.first)['range'];self.probe.raw+='changed'
        with self.assertRaises(ValueError):verify(self.probe,{},self.source,self.origin,self.target,['runner'],run=self.runner)
        self.probe.raw=self.raw
        snapshots=iter([(self.target,self.snapshot),(self.target,{'marks':{'updated':{}}})])
        self.probe.read=lambda _credentials:next(snapshots)
        with self.assertRaises(ValueError):verify(self.probe,{},self.source,self.origin,self.target,['runner'],run=self.runner)

    def test_origin_must_be_different_owned_chapter_and_source_matched(self):
        native=SimpleNamespace(request=lambda *_args,**_kwargs:{},download=lambda *_args:(b'archive','envelope'))
        model={'format':'epub','version':1,'chapters':[{'uid':37,'free_or_owned':True,'wordCount':20},
            {'uid':38,'free_or_owned':True,'wordCount':20}]}
        with patch('native_direct_cross_bookmark_trial.catalog',return_value=model), \
             patch('native_direct_cross_bookmark_trial.password',return_value='key'), \
             patch('native_direct_cross_bookmark_trial.read',return_value={'html':True,'source':b'origin'}):
            result=prepare_origin({'vid':'12345678'},self.source,probe=native)
            self.assertEqual(result['origin_uid'],'38')
            self.assertEqual(result['origin_source_sha256'],hashlib.sha256(b'origin').hexdigest())
            model['chapters'][1]['free_or_owned']=False
            with self.assertRaises(ValueError):prepare_origin({'vid':'12345678'},self.source,probe=native)


if __name__=='__main__':unittest.main()
