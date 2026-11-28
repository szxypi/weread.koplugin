#!/usr/bin/env python3
"""Read-only full-book cached-search validation; private data stays in memory.

The selected account's complete CB_ chapter set is read using the existing
bounded protocol and pacing. Real source is piped into two isolated tmpfs
KOReader profiles, with no credentials or network access in the UI processes.
"""
import argparse
import hashlib
import json
import resource
import subprocess

from fetch_weread_epub import decode_content_shards
from secure_weread_session import COOKIE_NAMES, SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_full_reading import CbFullReadingProbe
from verify_cb_reading import CbReadingProbe, baseline_position, readable_chapters
from verify_source_coordinates import CoordinateError, FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, versions


class MemoryFullProbe(CbFullReadingProbe):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.private_shards={}
        self.private_sources={}
        self.catalog_snapshot=None
        self.shelf_hash=None

    def request(self, stage, *args, **kwargs):
        result=super().request(stage,*args,**kwargs)
        if stage=='shelf':
            self.shelf_hash=state_hash(result)
        elif stage=='catalog_before':
            record,chapters=readable_chapters(result,self.book_id)
            self.catalog_snapshot=(chapters,versions(record))
        elif stage in ('e_0','e_1','e_3'):
            if not isinstance(result,str) or not self.chapter:raise ValueError('source_scope')
            parts=self.private_shards.setdefault(self.chapter,{})
            if stage in parts:raise ValueError('source_repeated')
            parts[stage]=result
            if stage=='e_3':
                if set(parts)!={'e_0','e_1','e_3'}:raise ValueError('source_incomplete')
                source=decode_content_shards(parts['e_0'],parts['e_1'],parts['e_3'])
                if not 0<len(source.encode())<=2*1024*1024:raise ValueError('source_size')
                self.private_sources[self.chapter]=source
                del self.private_shards[self.chapter]
        return result


def unique_query(sources, preferred):
    if preferred not in sources:
        raise ValueError('search_chapter_missing')
    texts = {}
    for uid, raw in sources.items():
        try:
            model = FilteredSource(raw, allow_multiple_bodies=True)
        except CoordinateError:
            raise ValueError('search_source_projection') from None
        texts[uid] = ''.join(char for char in model.characters if not char.isspace())

    other_chapters = sorted((uid for uid in texts if uid != preferred), key=lambda uid: -len(texts[uid]))
    for uid in (preferred, *other_chapters):
        text = texts[uid]
        others = [value for chapter, value in texts.items() if chapter != uid]
        model = None
        for width in (16, 12):
            for at in range(min(max(len(text) - width + 1, 0), 20000)):
                keyword = text[at:at + width]
                if (not keyword.isalnum() or text.find(keyword) != at or text.find(keyword, at + 1) >= 0
                        or any(keyword in other for other in others)):
                    continue
                if model is None:
                    model = FilteredSource(sources[uid], allow_multiple_bodies=True)
                    indices = [i for i, char in enumerate(model.characters) if not char.isspace()]
                offset = model.starts[indices[at]]
                try:
                    model.anchor_at(offset)
                except CoordinateError:
                    continue
                return uid, keyword, offset
    raise ValueError('search_no_unique_query')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--candidate',default='/validation/full-index-final-600/candidate.zip')
    args=parser.parse_args(argv)
    if not args.candidate.startswith('/validation/') or '\x00' in args.candidate:parser.error('invalid candidate path')
    report={'result':'OFFLINE_ONLY','account_data_writes':0,'authentication_writes':0,'private_data_on_regular_disk':False}
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report['result']='UNVERIFIED';phase='session';web=after=saved=payload=None
    try:
        def progress(value):
            if value.get('completed',0)%10==0:
                print(json.dumps({'phase':'reading','completed':value['completed'],'total':value['total']}),flush=True)
        store=SessionStore();saved=store.load();web=MemoryFullProbe(progress=progress)
        web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();phase='read_only_full_book';sample=web.prepare(1)
        manifest=sample['full_manifest'];sources=web.private_sources
        if web.private_shards or len(sources)!=len(manifest):raise ValueError('source_incomplete')
        entries=[]
        for row in manifest:
            uid=row['chapter_uid'];source=sources.get(uid)
            if (not isinstance(source,str) or hashlib.sha256(source.encode()).hexdigest()!=row['raw_sha256']
                    or len(source.encode())!=row['raw_bytes']):raise ValueError('source_changed')
            entries.append(dict(uid=uid,source=source))
        phase='source_match';target,keyword,offset=unique_query(sources,sample['chapter_uid'])
        other=next((row['uid'] for row in entries if row['uid']!=target),None)
        if not other:raise ValueError('missing_second_chapter')
        payload=dict(book=sample['book_id'],chapter=target,local_chapter=other,source=sources[target],
                     keyword=keyword,offset=offset,entries=entries)
        encoded=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
        if len(encoded)>8*1024*1024:raise ValueError('input_limit')
        report['alternate_chapter']=target!=sample['chapter_uid']
        phase='native_ui';print(json.dumps({'phase':'native_ui','screens':2,'chapters':len(entries),
                                            'alternate_chapter':report['alternate_chapter']}),flush=True)
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            command=['docker','exec','-i','-w','/source','weread-validation','xvfb-run','-a','python3',
                'scripts/run_owner_catalog_free_ui.py','--koreader','/validation/runtime/lib/koreader',
                '--candidate',args.candidate,'--width',str(width),'--height',str(height),'--dpi',str(dpi),'--full']
            child=subprocess.run(command,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=480)
            if child.returncode or len(child.stdout)>65536:raise ValueError('native_ui')
            value=json.loads(child.stdout)
            if value!=dict(result='PASS',profile_removed=True,installed_bytes_match=True,native_navigation=True,
                           bookshelf_resume=True,prior_position_preserved=True,offline=True):raise ValueError('native_ui')
        phase='independent_readback';after=CbReadingProbe();after.vid=web.vid;after.book_id=web.book_id;after.allowed={web.book_id}
        for cookie in web.cookies:
            if cookie.name in COOKIE_NAMES and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/':
                after.set_cookie(cookie.name,cookie.value)
        after.verify_account()
        observed=baseline_position(after.request('progress_after',BASE+'/web/book/getProgress?bookId='+after.book_id),after.book_id)
        shelf=after.request('shelf',BASE+'/web/shelf/sync')
        record,chapters=readable_chapters(after.request('catalog_before',BASE+'/web/book/chapterInfos',
                                                       {'bookIds':[after.book_id]}),after.book_id)
        if observed!=sample['baseline']:raise ValueError('position_changed')
        if state_hash(shelf)!=web.shelf_hash or [str(row['bookId']) for row in shelf['books']]!=web.shelf_ids:
            raise ValueError('shelf_changed')
        if (chapters,versions(record))!=web.catalog_snapshot:raise ValueError('catalog_changed')
        after.verify_account()
        save_refreshed_web_session(store,saved,after)
        report.update(result='PASS',chapters=len(entries),native_ui_screens=2,position_unchanged=True,
                      shelf_unchanged=True,catalog_unchanged=True,offline=True)
    except Exception as error:
        report['phase']=phase
        if (type(error) is ValueError and len(error.args)==1 and isinstance(error.args[0],str)
                and error.args[0] in {'search_chapter_missing','search_source_projection','search_no_unique_query',
                                      'position_changed','shelf_changed','catalog_changed'}):
            report['reason']=error.args[0]
    finally:
        if web:
            report['completed_chapters']=web.completed
            web.private_shards.clear();web.private_sources.clear();web.samples.clear();web.manifest.clear();web.close()
            web.catalog_snapshot=web.shelf_hash=None
        if after:after.close()
        if saved:saved.clear()
        if payload:payload.clear()
    print(json.dumps(report),flush=True)
    return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
