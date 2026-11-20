#!/usr/bin/env python3
"""Verify Unicode offline search against real owner source without data writes.

The account, source, keyword and coordinates remain in memory/captured pipes;
KOReader profiles and derived EPUBs are confined to a disposable tmpfs.
"""
import argparse
import json
import re
import resource
import subprocess
import unicodedata

from cb_cloud_position import observed
from secure_weread_session import COOKIE_NAMES, SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_reading import BASE, CbReadingProbe, baseline_position, readable_chapters
from verify_cb_native_time_guarded_dry import trusted_command
from verify_source_coordinates import CoordinateError, FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import versions


def find_query(raw):
    """Return one original source offset and an independently folded variant."""
    model=FilteredSource(raw,allow_multiple_bodies=True)
    indices=[i for i,char in enumerate(model.characters) if not char.isspace()]
    flat=''.join(model.characters[i] for i in indices)
    folded=unicodedata.normalize('NFD',unicodedata.normalize('NFKC',flat).casefold())
    for match in re.finditer(r'[A-Za-z]{8,20}',flat[:20000]):
        word=match.group(0);needle=word.casefold();first=folded.find(needle)
        if first<0 or folded.find(needle,first+1)>=0:continue
        offset=model.starts[indices[match.start()]]
        try:model.anchor_at(offset)
        except CoordinateError:continue
        fullwidth=''.join(chr(ord(char.upper())+0xFEE0) for char in word)
        if unicodedata.normalize('NFKC',fullwidth).casefold()!=needle:raise ValueError('fold')
        return fullwidth,offset
    return None


def find_canonical_query(raw):
    """Select one unique source span with a decomposable letter, in memory."""
    model=FilteredSource(raw,allow_multiple_bodies=True)
    indices=[i for i,char in enumerate(model.characters) if not char.isspace()]
    flat=''.join(model.characters[i] for i in indices)
    folded=unicodedata.normalize('NFD',unicodedata.normalize('NFKC',flat).casefold())
    examined=0
    for index,char in enumerate(flat):
        if not char.isalpha() or unicodedata.normalize('NFD',char)==char:continue
        examined+=1
        if examined>64:break
        start=max(0,index-6);original=flat[start:start+16]
        if len(original)<12:continue
        query=unicodedata.normalize('NFD',original)
        if query==original or len(query.encode())>160:continue
        needle=unicodedata.normalize('NFD',unicodedata.normalize('NFKC',query).casefold())
        first=folded.find(needle)
        if first<0 or folded.find(needle,first+1)>=0:continue
        offset=model.starts[indices[start]]
        try:model.anchor_at(offset)
        except CoordinateError:continue
        return query,offset
    return None


class Probe(CbReadingProbe):
    def __init__(self):
        super().__init__();self.shelf_hash=None;self.catalog_versions={};self.progress_before={}

    def request(self,stage,url,body=None,**kwargs):
        value=super().request(stage,url,body,**kwargs)
        if stage=='shelf':
            if not isinstance(value,dict) or not isinstance(value.get('archive'),list):raise ValueError('shelf')
            self.shelf_hash=state_hash(value)
        elif stage=='progress_before':
            self.progress_before[self.book_id]=value
        elif stage=='catalog_after':
            record,_=readable_chapters(value,self.book_id)
            self.catalog_versions[self.book_id]=versions(record)
        return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--candidate')
    parser.add_argument('--kind',choices=('fullwidth','canonical'),default='fullwidth')
    args=parser.parse_args(argv)
    if args.saved_session and not args.candidate:parser.error('saved session requires a candidate')
    if args.candidate and not re.fullmatch(r'/validation/cb-dry-candidate-[a-f0-9]{64}\.zip',args.candidate):parser.error('invalid candidate')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,private_data_on_regular_disk=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=web=after=payload=None;phase='session'
    try:
        phase='candidate_attestation'
        if trusted_command()[-1]!=args.candidate:raise ValueError('candidate')
        store=SessionStore();saved=store.load();web=Probe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();phase='source_read';samples=web.prepare();web.verify_account()
        phase='sample_selection';selected=choice=None
        for sample in samples:
            if sample['source_format']!='web_xhtml' or int(sample['chapter_uid'])>2147483647:continue
            other=next((str(row.get('chapterUid')) for row in sample['chapters']
                        if str(row.get('chapterUid','')).isdigit() and str(row['chapterUid'])!=sample['chapter_uid']
                        and 0<int(row['chapterUid'])<=2147483647),None)
            if not other:continue
            candidate=(find_canonical_query if args.kind=='canonical' else find_query)(sample['source'])
            if candidate:
                selected=sample;choice=(candidate[0],candidate[1],other);break
        if selected is None:raise ValueError('no_sample')
        if selected['book_id'] not in web.catalog_versions or not web.shelf_hash:raise ValueError('baseline')
        save_refreshed_web_session(store,saved,web)
        fresh=store.load()
        if fresh['vid']!=saved['vid']:raise ValueError('account')
        saved.clear();saved=fresh
        payload=dict(book=selected['book_id'],chapter=selected['chapter_uid'],local_chapter=choice[2],
                     source=selected['source'],format='web_xhtml',keyword=choice[0],offset=choice[1],ignore_case=True)
        encoded=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
        if len(encoded)>8*1024*1024:raise ValueError('input_limit')
        phase='native_source'
        cmd=['docker','exec','-i','-w','/validation/runtime/lib/koreader','weread-validation',
             'sh','-c','ulimit -c 0; exec "$@"','sh','./luajit','/source/spec/koreader/owner_cached_search_probe.lua']
        child=subprocess.run(cmd,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=120)
        marker=b'\nWEREAD_OWNER_CACHED_SEARCH='
        if child.returncode or len(child.stdout)>65536 or child.stdout.count(marker)!=1:raise ValueError('native_source')
        if json.loads(child.stdout.split(marker,1)[1].splitlines()[0])!={'result':'PASS','checked':1}:raise ValueError('native_source')
        phase='native_ui';passed=0
        for full in (False,True):
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                cmd=['docker','exec','-i','-w','/source','-e','SDL_VIDEODRIVER=dummy','weread-validation','python3',
                     'scripts/run_owner_catalog_free_ui.py','--koreader','/validation/runtime/lib/koreader',
                     '--candidate',args.candidate,'--width',str(width),'--height',str(height),'--dpi',str(dpi)]
                if full:cmd.append('--full')
                child=subprocess.run(cmd,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=480)
                if child.returncode or len(child.stdout)>65536:raise ValueError('native_ui')
                value=json.loads(child.stdout)
                if value!=dict(result='PASS',profile_removed=True,installed_bytes_match=True,native_navigation=True,
                               bookshelf_resume=True,prior_position_preserved=True,offline=True):raise ValueError('native_ui')
                passed+=1
        phase='independent_readback';after=CbReadingProbe();after.vid=saved['vid'];after.book_id=selected['book_id'];after.allowed={selected['book_id']}
        for key,value in saved['cookies'].items():
            if key in COOKIE_NAMES:after.set_cookie(key,value)
        after.verify_account()
        raw_progress=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+after.book_id)
        progress=baseline_position(raw_progress,after.book_id)
        shelf=after.request('shelf',BASE+'/web/shelf/sync')
        if not isinstance(shelf,dict) or not isinstance(shelf.get('archive'),list):raise ValueError('shelf')
        record,chapters=readable_chapters(after.request('catalog_before',BASE+'/web/book/chapterInfos',dict(bookIds=[after.book_id])),after.book_id)
        if (progress!=selected['baseline'] or observed(raw_progress,after.book_id,selected['chapters'],'web')
                !=observed(web.progress_before[after.book_id],after.book_id,selected['chapters'],'web')
                or state_hash(shelf)!=web.shelf_hash
                or [str(row['bookId']) for row in shelf['books']]!=web.shelf_ids
                or chapters!=selected['chapters'] or versions(record)!=web.catalog_versions[after.book_id]):raise ValueError('changed')
        after.verify_account();save_refreshed_web_session(store,saved,after)
        report.update(result='PASS',read_only_books_checked=len(samples),native_cases=passed,query_kind=args.kind,
                      source_position_verified=True,offline_reopen=True,position_shelf_catalog_unchanged=True)
    except Exception as error:
        report.update(result='UNVERIFIED',phase=phase)
        allowed={'candidate','no_sample','baseline','account','input_limit','native_source','native_ui','shelf','changed'}
        report['reason']=str(error) if type(error) is ValueError and str(error) in allowed else 'other'
    finally:
        if web:web.samples.clear();web.catalog_versions.clear();web.progress_before.clear();web.close()
        if after:after.samples.clear();after.close()
        if saved:saved.clear()
        if payload:payload.clear()
    print(json.dumps(report));return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
