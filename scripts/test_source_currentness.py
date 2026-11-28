"""Offline identity/current-source checks; no credentials or account writes."""
from contextlib import redirect_stdout,redirect_stderr
import copy
import hashlib
import io
import json
import unittest
from unittest.mock import patch

from source_currentness import project,catalog,version
import verify_source_currentness as task

RAW='<html><body><p>Original selected chapter body.</p></body></html>'
EXPECTED=dict(book_id='900001',chapter_uid='11',chapter_idx=0,raw_sha256=hashlib.sha256(RAW.encode()).hexdigest(),raw_bytes=len(RAW.encode()))
CATALOG=[dict(bookId='900001',book=dict(bookVersion=3),updated=[dict(chapterUid=11,chapterIdx=0,wordCount=30,version=5)])]
READER=dict(book_id='900001',psvts='synthetic-reader-session',current_chapter=dict(chapterUid=22),progress=dict(chapterUid=22))


class CurrentnessTests(unittest.TestCase):
    def test_default_is_offline_without_loading_credentials(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_no_write_or_implicit_native_http_mode(self):
        for args in (['--apply'],['--native-http'],['--lua-command','synthetic']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

    def test_identity_byte_match_is_independent_of_cloud_chapter(self):
        value=project(EXPECTED,CATALOG,READER,RAW,CATALOG)
        self.assertTrue(value['source_current']);self.assertFalse(value['upload_verified'])
        self.assertEqual(value['chapter_idx'],0);self.assertEqual(value['chapter_uid'],'11')
        self.assertNotIn('psvts',value);self.assertNotIn('raw',value)

    def test_changed_bytes_or_length_never_pass(self):
        with self.assertRaises(ValueError):project(EXPECTED,CATALOG,READER,RAW+'x',CATALOG)
        changed=dict(EXPECTED,raw_bytes=EXPECTED['raw_bytes']+1)
        with self.assertRaises(ValueError):project(changed,CATALOG,READER,RAW,CATALOG)

    def test_catalog_changes_or_wrong_explicit_index_are_rejected(self):
        for key in ('bookVersion','chapterIdx'):
            after=copy.deepcopy(CATALOG)
            if key=='bookVersion':after[0]['book']['bookVersion']=4
            else:after[0]['updated'][0]['chapterIdx']=1
            with self.assertRaises(ValueError):project(EXPECTED,CATALOG,READER,RAW,after)
        with self.assertRaises(ValueError):project(dict(EXPECTED,chapter_idx=1),CATALOG,READER,RAW,CATALOG)

    def test_metadata_version_alone_never_replaces_source_byte_identity(self):
        changed=copy.deepcopy(CATALOG);changed[0]['book']['bookVersion']=4
        self.assertTrue(project(EXPECTED,changed,READER,RAW,changed)['source_current'])
        with self.assertRaises(ValueError):project(EXPECTED,changed,READER,RAW+'changed',changed)

    def test_ambiguous_rejected_or_foreign_catalogs_fail(self):
        values=[CATALOG*2,dict(errcode=False,data=CATALOG),dict(succ=False,data=CATALOG),dict(errcode=-1,data=CATALOG),dict(data=False,books=CATALOG)]
        for mutate in ('duplicate_uid','foreign_nested','missing_index','conflicting_index','empty_updated','false_updated'):
            value=copy.deepcopy(CATALOG)
            if mutate=='duplicate_uid':value[0]['updated']*=2
            if mutate=='foreign_nested':value[0]['book']['bookId']='900002'
            if mutate=='missing_index':del value[0]['updated'][0]['chapterIdx']
            if mutate=='conflicting_index':value[0]['updated'][0]['chapter_idx']=1
            if mutate=='empty_updated':value[0]['chapters']=value[0]['updated'];value[0]['updated']=[]
            if mutate=='false_updated':value[0]['chapters']=value[0]['updated'];value[0]['updated']=False
            values.append(value)
        for value in values:
            with self.assertRaises(ValueError):catalog(value,'900001','11')

    def test_invalid_descriptors_reader_and_version_types_fail(self):
        for key,bad in (('book_id','other'),('chapter_uid',True),('chapter_idx',True),('raw_bytes',False),('raw_sha256','bad')):
            with self.assertRaises(ValueError):project(dict(EXPECTED,**{key:bad}),CATALOG,READER,RAW,CATALOG)
        for reader in (dict(READER,book_id='900002'),dict(READER,psvts='bad\nvalue'),dict(READER,psvts=None)):
            with self.assertRaises(ValueError):project(EXPECTED,CATALOG,reader,RAW,CATALOG)
        for value in (True,-1,1.5,float('inf'),'version-3'):
            with self.assertRaises(ValueError):version(value)
        self.assertEqual(version('000123'),'123');self.assertEqual(version(0),'0')


if __name__=='__main__':unittest.main()
