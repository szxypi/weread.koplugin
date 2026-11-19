#!/usr/bin/env python3
"""Offline tests for the TXT official-selection comparison."""
import argparse
import base64
from copy import deepcopy
import hashlib
import unittest
from unittest.mock import patch

from cb_txt_highlight_trial import BODY, TEXT
from cb_txt_official_selection import DRAW_HOOK, FIND_POINTS, verify_capture
from personal_upload_trial import Journal
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend, credentials
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_official_selection as experiment
from verify_synthetic_epub_upload import run as upload_run


def fixture(*,bom=False):
    raw=('\ufeff' if bom else '')+BODY.decode();source=raw.removeprefix('\ufeff')
    quote=TEXT[:8];start=source.index(quote)
    sample=dict(book_id='CB_Synthetic42',chapter_uid='2',source_format='web_txt',source=raw,chapters=[dict(chapterUid=2)])
    row=dict(bookId=sample['book_id'],chapterUid=2,type=1,range=f'{start}-{start+len(quote)}',
             markText=base64.b64encode(quote.encode()).decode())
    return sample,row


class OfficialSelectionTests(unittest.TestCase):
    def test_exact_official_selection_after_non_bmp_and_bom(self):
        for bom in (False,True):
            sample,row=fixture(bom=bom);result=verify_capture(sample,row)
            self.assertEqual(result['result'],'PASS');self.assertTrue(result['attempted_write_blocked'])
            self.assertTrue(result['non_bmp_before_selection'])

    def test_incorrect_range_and_scope_are_rejected(self):
        sample,row=fixture();start,end=map(int,row['range'].split('-'))
        variants=[dict(row,range=f'{start+1}-{end+1}'),dict(row,bookId='CB_Other'),dict(row,chapterUid=3),
                  dict(row,markText='not base64!'),dict(row,type=True),dict(row,markText=base64.b64encode(b'other').decode())]
        for value in variants:
            with self.subTest(value=value),self.assertRaises(ValueError):verify_capture(sample,value)
        changed=deepcopy(sample);changed['source']=changed['source'].replace('😀','x')
        with self.assertRaises(ValueError):verify_capture(changed,row)
        changed=deepcopy(sample);changed['source']+=TEXT
        with self.assertRaises(ValueError):verify_capture(changed,row)

    def test_isolated_upload_cleans_up_after_success_or_observation_failure(self):
        for succeeds in (True,False):
            grant=credentials();saved=dict(vid=grant['vid'],cookies={});probe=FakeProbe()
            journal=Journal(Backend(),validator=experiment.validate_plan);receipt=Receipt(Backend())
            class Native:
                def load(self,_owner):return grant
            class Web:
                def __init__(self):self.samples=[];self.last_checks={}
                def set_cookie(self,*_args):pass
                def verify_account(self):pass
                def close(self):pass
                def inspect(self,target):
                    raw=BODY.decode();self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
                    return dict(book_id=target,chapter_uid='2',chapters=[dict(chapterUid=2)],source_format='web_txt',
                                source=raw,source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),baseline={'chapter':'0'})
            def uploader(*args,**kwargs):return upload_run(*args,**kwargs,sleep=lambda _:None,now=lambda:1000)
            def browser(sample,_cookies):
                if not succeeds:raise ValueError('synthetic_browser_failure')
                synthetic,row=fixture();row['bookId']=sample['book_id']
                return verify_capture(sample,row)
            with self.subTest(succeeds=succeeds),patch.object(experiment,'save_refreshed_web_session',return_value=False):
                result=experiment.run(saved,None,Native(),grant,journal,receipt,apply=True,upload_fn=uploader,
                                      probe_factory=lambda *_:probe,source_factory=Web,observe_fn=browser,sleep=lambda _:None)
                self.assertEqual(result['result'],'OFFICIAL_TXT_SELECTION_VERIFIED' if succeeds else 'UNVERIFIED')
                self.assertEqual(result['annotation_posts'],0);self.assertEqual(probe.attempts['cleanup'],1)
                self.assertEqual(journal.read()[0]['phase'],'restored')
                self.assertEqual(result['upload']['restore_observed'],True)
                self.assertNotIn(TEXT,str(result))


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--browser',action='store_true');args=parser.parse_args()
    if not unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(OfficialSelectionTests)).wasSuccessful():return 1
    if args.browser:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            browser=p.chromium.launch(channel='chrome',headless=True);page=browser.new_page(viewport=dict(width=1024,height=768))
            page.add_init_script(DRAW_HOOK);page.goto('about:blank')
            page.set_content('<canvas width="800" height="200"></canvas>')
            page.evaluate('''text=>{const c=document.querySelector('canvas').getContext('2d');c.font='20px sans-serif';
                let x=30;for(const ch of text){c.fillText(ch,x,80);x+=c.measureText(ch).width}}''',TEXT)
            points=page.evaluate(FIND_POINTS,TEXT)
            assert points and points['start']['x']<points['end']['x'] and abs(points['start']['y']-points['end']['y'])<8
            assert page.evaluate(FIND_POINTS,'not present') is None
            browser.close()
        print('offline browser geometry: PASS')
    return 0


if __name__=='__main__':raise SystemExit(main())
