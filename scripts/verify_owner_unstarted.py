#!/usr/bin/env python3
"""Read-only normal ReaderUI no-chapter handling, plus fresh offline reopening."""
import argparse
from copy import deepcopy
from datetime import datetime,timezone
import json,resource,subprocess,threading
from verify_txt_reading import TxtProbe
from verify_native_reader_trial import reading_payload
from verify_native_txt_roundtrip import source_hash,catalog_hash
from verify_source_remote_position import observation
from source_remote_position import outcome,public_report
from verify_reader_progress import find_node
from verify_web_source_progress import BASE
from verify_eink_login import BASE as NATIVE
from verify_native_txt_position import Native
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_translation_preflight import save_refreshed_web_session
from owner_unstarted_contract import validate_payload,decode_runner,compare


class SkipBook(ValueError):pass


class Source(TxtProbe):
    def inspect_book(self,book_id,hint=None):
        try:return super().inspect_book(book_id,hint)
        except SkipBook:self.sample=None;return False
    def choose_chapter(self,chapters):
        raw=self.request('progress_before',BASE+'/web/book/getProgress?bookId='+self.book_id)
        if outcome(raw,self.book_id,chapters).get('reason')!='progress_no_chapter':raise SkipBook('unstarted/not_no_chapter')
        first=chapters[0] if chapters else {}
        words=first.get('wordCount')
        if (type(words) not in (int,float) or not 200<=words<=100000000
                or not str(first.get('chapterUid','')).isdigit() or int(first['chapterUid'])<=0):raise SkipBook('unstarted/short_first_chapter')
        self.before=raw;return dict(first,chapterUid=str(first['chapterUid']))


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);access=p.add_mutually_exclusive_group();access.add_argument('--saved-session',action='store_true');access.add_argument('--mock',action='store_true')
    p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if bool(a.lua_command)!=bool(a.saved_session or a.mock):p.error('explicit session and private reader command required')
    r=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,
           private_data_on_regular_disk=False,synthetic_only=a.mock)
    web=grant=saved=server=api=None;phase='init';private_literals=set()
    try:
        if a.saved_session or a.mock:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            if a.mock:
                from native_reader_fixture import NativeReaderServer,GRANT,BOOK_ID
                server=NativeReaderServer();server.progress[BOOK_ID]=dict(chapterUid=0,chapterOffset=0,progress=0,readingTime=0,recordReadingTime=0,ttsTime=0)
                threading.Thread(target=server.serve_forever,daemon=True).start();grant=deepcopy(GRANT)
                class MockSource(Source):
                    def inspect_book(self,book_id,hint=None):return super().inspect_book(book_id,'txt' if book_id==BOOK_ID else hint)
                    def request(self,stage,url,body=None,**options):
                        status,v=server.route('POST' if body is not None else 'GET',url,body or {})[:2]
                        self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('unstarted/mock_response')
                        return json.dumps(v) if options.get('as_json') is False and not isinstance(v,str) else v
                class MockNative(Native):
                    def request(self,stage,url,body=None,credentials=None,timeout=15):
                        if body is not None or credentials!=grant:raise ValueError('unstarted/mock_scope')
                        status,v=server.route('GET',url,{})[:2];self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('unstarted/mock_response')
                        return v
                web=MockSource();web.vid=GRANT['vid'];web.set_cookie('wr_vid',web.vid);web.set_cookie('wr_skey','mock_key');native_factory=MockNative
            else:
                from verify_native_thought_trial import other_pending
                if other_pending():raise ValueError('unstarted/pending')
                store=SessionStore();saved=store.load();grant=NativeSessionStore().load(saved['vid']);web=Source();web.vid=saved['vid']
                for k,v in saved['cookies'].items():web.set_cookie(k,v)
                native_factory=Native
            private_literals.update(str(v) for v in grant.values());private_literals.add(web.vid)
            phase='source';web.verify_account()
            if not web.find_sample(limit=32):raise ValueError('unstarted/no_source')
            key=web.book_id;raw=web.sample['plain'];source_before=source_hash(web);catalog_before=catalog_hash(web)
            original_web=observation(web.before,key)
            def web_check():
                current=web.request('progress_after',BASE+'/web/book/getProgress?bookId='+key)
                if observation(current,key)!=original_web or outcome(current,key,web.sample['chapters']).get('reason')!='progress_no_chapter':raise ValueError('unstarted/web_changed')
            api=native_factory(grant,key)
            def native_state():
                current=api.request('unstarted_position',NATIVE+'/book/getProgress?bookId='+key,credentials=grant)
                if outcome(current,key,web.sample['chapters'],'native').get('reason')!='progress_no_chapter':raise ValueError('unstarted/native_changed')
                metadata=api.request('unstarted_metadata',NATIVE+'/book/info?bookId='+key,credentials=grant)
                if str(metadata.get('bookId'))!=key:raise ValueError('unstarted/foreign_metadata')
                shelf=api.request('unstarted_shelf',NATIVE+'/shelf/sync',credentials=grant)
                return dict(observation=observation(current,key),metadata={k:metadata[k] for k in ('bookId','bookVersion','version','format') if k in metadata},shelf_hash=state_hash(shelf))
            before=native_state();web_check();web.reader_shelf=web.request('shelf',BASE+'/web/shelf/sync');shelf_before=state_hash(web.reader_shelf)
            if not a.mock:save_refreshed_web_session(store,saved,web);saved=store.load()
            cookies={c.name:c.value for c in web.cookies} if a.mock else dict(saved['cookies'])
            payload=reading_payload(web);payload.update(vid=web.vid,cookies=cookies,native_source_excerpt=True,unstarted_preview=True)
            if a.mock:payload['unstarted_mock_port']=server.server_port
            validate_payload(payload,server.server_port if server else None)
            private_literals.update((key,payload['source_text'],*cookies.values()))
            command=[str(server.server_port) if server and x=='@MOCK_PORT@' else x for x in a.lua_command]
            phase='reader';child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=420)
            v=decode_runner(child.stdout,web.vid);r['ui']=v['report']
            if child.returncode or v['report']['result']!='PASS':raise ValueError('unstarted/runtime')
            compare(v['candidate_private'],payload,raw)
            for k,value in v['cookies'].items():web.set_cookie(k,value)
            phase='independent_after';web.verify_account()
            if not web.find_sample(book_id=key) or source_hash(web)!=source_before or catalog_hash(web)!=catalog_before:raise ValueError('unstarted/source_changed')
            web_check()
            if native_state()!=before or state_hash(web.request('shelf',BASE+'/web/shelf/sync'))!=shelf_before:raise ValueError('unstarted/cloud_changed')
            if not a.mock and NativeSessionStore().load(web.vid)!=grant:raise ValueError('unstarted/grant_changed')
            if server and server.native_posts:raise ValueError('unstarted/mock_writes')
            r.update(result='OWNER_UNSTARTED_READER_VERIFIED',independent_local_comparisons=4,cloud_no_chapter_and_counts_preserved=True,
                     source_catalog_unchanged=True,grants_retained=True,fresh_offline_process=True,initialization_write_implemented=False)
    except (Exception,KeyboardInterrupt) as error:
        r.update(result='UNVERIFIED',failure_stage=phase)
        import re
        if isinstance(error,ValueError) and re.fullmatch('unstarted/[a-z_]+',str(error)):r['reason']=str(error)
    finally:
        if web:
            if not a.mock and web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,store.load(),web)
                except Exception:r['result']='UNVERIFIED'
            r['web_stages']=[{k:x[k] for k in ('stage','status','api_code') if k in x} for x in web.report['stages']];web.sample=None;web.close()
        if api:r['native_stages']=[{k:x[k] for k in ('stage','status','error_code') if k in x} for x in api.report['stages']]
        if server:r['mock_server_posts']=server.native_posts;server.shutdown();server.server_close()
        for v in (saved,grant):
            if v:v.clear()
    r=public_report(r,private_literals)
    print(json.dumps(r,indent=2));return int(r['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
