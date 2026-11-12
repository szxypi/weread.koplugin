#!/usr/bin/env python3
"""Default offline; real cloud choice is read-only and cannot renew or upload."""
import argparse
from copy import deepcopy
from datetime import datetime,timezone
import json
import resource
import subprocess
import threading
from owner_cloud_source_contract import decode_runner,compare
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from verify_native_reader_trial import ReadingSource,reading_payload
from verify_native_txt_position import Native
from verify_raw_txt_excerpt import candidate
from verify_native_txt_roundtrip import source_hash,catalog_hash
from verify_reader_progress import project,find_node
from verify_native_position_lua import equivalent
from shelf_flag_change_contract import state_hash
from readtime_upload_model import integer
from verify_translation_preflight import save_refreshed_web_session
from verify_eink_login import BASE


def observe(api,grant,book):
    raw=api.request('cloud_ui_position',BASE+'/book/getProgress?bookId='+book,credentials=grant);p=project(raw,book,'native')
    point={k:p[k] for k in ('book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')};point['chapter_uid']=str(point['chapter_uid'])
    counts={k:find_node(raw,book)[k] for k in ('readingTime','recordReadingTime','ttsTime')}
    if any(not integer(v,0,2**53-1) for v in counts.values()):raise ValueError('cloud_choice/counts')
    info=api.request('cloud_ui_info',BASE+'/book/info?bookId='+book,credentials=grant)
    versions=[info[k] for k in ('version','bookVersion') if k in info]
    if str(info.get('bookId'))!=book or not versions or any(not integer(v,0,2147483647) or v!=versions[0] for v in versions):raise ValueError('cloud_choice/version')
    shelf=api.request('cloud_ui_shelf',BASE+'/shelf/sync',credentials=grant)
    return dict(point=point,counts=counts,version=versions[0],shelf_sha256=state_hash(shelf))


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);access=p.add_mutually_exclusive_group();access.add_argument('--saved-session',action='store_true');access.add_argument('--mock',action='store_true')
    p.add_argument('--book-from-retired-close',action='store_true');p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if bool(a.lua_command)!=bool(a.saved_session or a.mock) or a.book_from_retired_close and not a.saved_session:p.error('paired explicit session and private reader command required')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False)
    web=api=grant=saved=store=server=reference=None;secrets=set();phase='init'
    try:
        if a.saved_session or a.mock:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));report['synthetic_only']=a.mock
            if a.mock:
                from native_reader_fixture import NativeReaderServer,GRANT,BOOK_ID,chapter_txt
                from txt_coordinates import PlainSource
                server=NativeReaderServer();threading.Thread(target=server.serve_forever,daemon=True).start()
                text=chapter_txt(2);co=PlainSource(text).locate('这是第2章的第1段。窗外的风穿过树梢')[0]
                server.progress[BOOK_ID].update(chapterOffset=co,summary=PlainSource(text).excerpt(co)['text'])
                grant=deepcopy(GRANT);identity=BOOK_ID
                class MockSource(ReadingSource):
                    def inspect_book(self,book_id,hint=None):return super().inspect_book(book_id,'txt' if book_id==BOOK_ID else hint)
                    def request(self,stage,url,body=None,**options):
                        status,value=server.route('POST' if body is not None else 'GET',url,body or {})[:2]
                        self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('cloud_choice/mock_response')
                        return json.dumps(value) if options.get('as_json') is False and not isinstance(value,str) else value
                web=MockSource();web.vid=grant['vid'];web.set_cookie('wr_vid',web.vid);web.set_cookie('wr_skey','mock_key')
                class MockNative(Native):
                    def request(self,stage,url,body=None,credentials=None,timeout=15):
                        if body is not None or credentials!=self.credentials or self.reads>=12 or url not in {
                                BASE+'/book/getProgress?bookId='+self.identity,BASE+'/book/info?bookId='+self.identity,BASE+'/shelf/sync'}:
                            raise ValueError('cloud_choice/native_scope')
                        self.reads+=1;status,value=server.route('GET',url,{})[:2];self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('cloud_choice/mock_response')
                        return value
                native_factory=MockNative
            else:
                from verify_native_thought_trial import other_pending
                if other_pending():raise ValueError('cloud_choice/pending')
                store=SessionStore();saved=store.load();grant=NativeSessionStore().load(saved['vid']);identity=None
                if a.book_from_retired_close:
                    from secure_native_close_trial import NativeCloseTrialStore
                    reference=NativeCloseTrialStore().read()
                    if not reference[0] or reference[0]['phase']!='retired' or reference[0]['posts']!=2:raise ValueError('cloud_choice/reference')
                    identity=reference[0]['plan']['baseline']['book_id']
                web=ReadingSource();web.vid=saved['vid']
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                native_factory=Native
            secrets.update(str(v) for v in grant.values());phase='source';web.verify_account()
            if not web.find_sample(book_id=identity,limit=16):raise ValueError('cloud_choice/no_source')
            baseline,target=candidate(web.sample['plain'],web.inspect_plan());raw=web.sample['plain'];catalog_before=catalog_hash(web)
            secrets.update((web.vid,web.book_id,baseline['summary'],target['summary']))
            api=native_factory(grant,web.book_id);before=observe(api,grant,web.book_id)
            if not equivalent(before['point'],baseline):raise ValueError('cloud_choice/baseline')
            web.reader_shelf=web.request('shelf','https://weread.qq.com/web/shelf/sync');shelf_before=state_hash(web.reader_shelf)
            if not a.mock:save_refreshed_web_session(store,saved,web);saved=store.load()
            cookies={c.name:c.value for c in web.cookies} if a.mock else dict(saved['cookies']);secrets.update(cookies.values())
            payload=reading_payload(web);payload.update(vid=web.vid,cookies=cookies,native_source_excerpt=True,raw_cloud_preview=dict(baseline=baseline,target=target))
            if server:payload['cloud_mock_port']=server.server_port
            command=[str(server.server_port) if server and x=='@MOCK_PORT@' else x for x in a.lua_command]
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>256*1024:raise ValueError('cloud_choice/input')
            phase='reader';child=subprocess.run(command,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=420)
            envelope=decode_runner(child.stdout,web.vid);report['ui']=envelope['report']
            if child.returncode or report['ui']['result']!='PASS':raise ValueError('cloud_choice/runtime')
            compare(envelope['candidate_private'],payload,raw)
            for key,value in envelope['cookies'].items():web.set_cookie(key,value)
            phase='independent_after';web.verify_account()
            if not web.find_sample(book_id=web.book_id) or catalog_hash(web)!=catalog_before or source_hash(web)!=payload['source_raw_sha256']:
                raise ValueError('cloud_choice/source_changed')
            later=web.inspect_plan()['baseline'];current={k:later[k] for k in baseline};current['chapter_uid']=str(current['chapter_uid'])
            if not equivalent(current,baseline) or not equivalent(observe(api,grant,web.book_id),before):raise ValueError('cloud_choice/cloud_changed')
            if state_hash(web.request('shelf','https://weread.qq.com/web/shelf/sync'))!=shelf_before:raise ValueError('cloud_choice/shelf_changed')
            if not a.mock and NativeSessionStore().load(web.vid)!=grant:raise ValueError('cloud_choice/grant_changed')
            if reference is not None and NativeCloseTrialStore().read()!=reference:raise ValueError('cloud_choice/reference_changed')
            if server and (server.native_posts or not server.preserved_counts()):raise ValueError('cloud_choice/mock_writes')
            report.update(result='OWNER_RAW_TXT_CLOUD_CHOICE_VERIFIED',independent_raw_position_checkpoint_comparisons=4,
                complete_web_native_cloud_and_counts_preserved=True,source_catalog_unchanged=True,credentials_unchanged=True,
                retired_reference_unchanged=reference is not None,fresh_offline_process=True)
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',failure_stage=phase)
        if isinstance(error,ValueError) and __import__('re').fullmatch('cloud_choice/[a-z_]+',str(error)):report['reason']=str(error)
    finally:
        if web:
            if not a.mock and web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,store.load(),web)
                except Exception:report['result']='UNVERIFIED'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.sample=None;web.close()
        if api:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in api.report['stages']]
        if server:server.shutdown();server.server_close()
        if grant:grant.clear()
        if saved:saved.clear()
    serialized=json.dumps(report,ensure_ascii=True)
    if any(len(value)>=8 and (value in serialized or json.dumps(value,ensure_ascii=True)[1:-1] in serialized) for value in secrets):
        report=dict(result='UNVERIFIED',reason='cloud_choice/report_privacy',account_data_posts=0,authentication_posts=0)
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
