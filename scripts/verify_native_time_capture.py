#!/usr/bin/env python3
"""Read-only real-native dwell capture; saves immutable provenance in Keychain.

No historical dispatch, renewal, clock edits, or changes to older capture scopes.
"""
import argparse,json,re,resource,threading,time
from copy import deepcopy
from datetime import datetime,timezone
from native_time_capture import NativeCaptureStore,validate
from run_native_time_capture import payload_valid
from verify_owner_reading import ReadingPreflight,reading_position
from fetch_weread_epub import normalize_chapter_infos,decode_content_shards
from verify_reader_progress import project as project_point,find_node
from verify_readtime_upload import counters
from readtime_history_capture import CaptureStore as OldCaptureStore
from verify_native_reader_trial import ReadingSource,reading_payload
from verify_native_txt_position import Native,compare
from verify_native_txt_roundtrip import source_hash,catalog_hash
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from verify_translation_preflight import save_refreshed_web_session
from verify_owner_reading import validate_cookies
from verify_eink_login import BASE
from verify_web_source_progress import BASE as WEB
from readtime_upload_model import integer

FRAME=b'\nWEREAD_NATIVE_TIME_CAPTURE_RESULT='


def snapshot(web,native,grant,plan):
    point,counts=compare(plan,native.request('native_capture_progress',BASE+'/book/getProgress?bookId='+web.book_id,credentials=grant),web.book_id)
    info=native.request('native_capture_metadata',BASE+'/book/info?bookId='+web.book_id,credentials=grant)
    version=info.get('bookVersion',info.get('version'))
    if str(info.get('bookId'))!=web.book_id or not integer(version,1,2147483647):raise ValueError('native_capture/version')
    record=web.sample['record'];book=record.get('book',{})
    versions=[node[k] for node in (record,book) for k in ('bookVersion','version') if k in node]
    if not versions or any(not integer(v,1,2147483647) or v!=version for v in versions):raise ValueError('native_capture/version')
    if any(not integer(info[k],1,2147483647) or info[k]!=version for k in ('bookVersion','version') if k in info):raise ValueError('native_capture/version')
    shelf=native.request('native_capture_shelf',BASE+'/shelf/sync',credentials=grant)
    return dict(point=point,counts=counts,version=version,shelf=state_hash(shelf),source=source_hash(web),catalog=catalog_hash(web))


class XhtmlSource(ReadingPreflight):
    requested_book=None
    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage in ('catalog_before','catalog_after'):
            self.record,self.chapters=normalize_chapter_infos(value,self.book_id)
        return value
    def select_shelf_book(self):
        # Prefer the previously verified book, never its consumed window.
        prior=OldCaptureStore().read()[0]
        if prior is None:return super().select_shelf_book()
        target=prior['plan']['source']['book_id']
        shelf=self.request('shelf',WEB+'/web/shelf/sync');ids={str(row.get('bookId')) for row in shelf.get('books',[]) if isinstance(row,dict)}
        if target not in ids:raise ValueError('native_capture/no_source')
        self.book_id=target;self.report['shelf_book_count']=len(shelf['books']);return target


def full_point(raw,book,kind):
    point=project_point(raw,book,kind);node=find_node(raw,book)
    indices=[node[k] for k in ('chapterIdx','chapterIndex','chapter_idx') if k in node]
    if (not point['has_chapter_offset'] or not indices
            or any(not integer(index,0,1000000) or index!=point['chapter_idx'] for index in indices)):raise ValueError('native_capture/point')
    optional={}
    for key in ('summary','chapterTitle'):
        if key not in node:optional[key]={'present':False}
        else:
            value=node[key]
            if not isinstance(value,str) or len(value.encode())>16384 or '\0' in value:raise ValueError('native_capture/point')
            optional[key]={'present':True,'value':value}
    return {k:point[k] for k in ('chapter_uid','chapter_idx','chapter_offset','raw_percent')}|optional



def xhtml_snapshot(web,native,grant):
    raw=native.request('native_capture_progress',BASE+'/book/getProgress?bookId='+web.book_id,credentials=grant)
    info=native.request('native_capture_metadata',BASE+'/book/info?bookId='+web.book_id,credentials=grant)
    version=info.get('bookVersion',info.get('version'))
    if str(info.get('bookId'))!=web.book_id or not integer(version,1,2147483647):raise ValueError('native_capture/version')
    book=web.record.get('book',{});versions=[node[k] for node in (web.record,book) for k in ('bookVersion','version') if k in node]
    if not versions:raise ValueError('native_capture/version')
    versions.extend(info[k] for k in ('bookVersion','version') if k in info)
    if any(not integer(v,1,2147483647) or v!=version for v in versions):raise ValueError('native_capture/version')
    remote=web.request('progress_after',WEB+'/web/book/getProgress?bookId='+web.book_id)
    shelf=native.request('native_capture_shelf',BASE+'/shelf/sync',credentials=grant)
    source=decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3')))
    return dict(point=full_point(raw,web.book_id,'native'),web_point=full_point(remote,web.book_id,'web'),counts=counters(raw,web.book_id),
        version=version,shelf=state_hash(shelf),source=__import__('hashlib').sha256(source.encode()).hexdigest(),
        catalog=digest(dict(book_id=web.book_id,versions=versions,chapters=web.chapters)))


def execute(payload,command):
    import subprocess
    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
    from native_trial_pipe import stop
    try:
        out,_err=child.communicate(json.dumps(payload,separators=(',',':')).encode(),timeout=220)
        if not isinstance(out,bytes) or len(out)>4*1024*1024 or out.count(FRAME)!=1:raise ValueError('native_capture/frame')
        result=json.loads(out.split(FRAME)[1]);validate_cookies(result['cookies'],payload['vid'])
        if child.returncode or result.get('result')!='PASS' or result.get('profile_removed') is not True:
            safe={k:result[k] for k in ('diagnostic','capture_failed_line','failure_type','failure_reason') if k in result}
            error=ValueError('native_capture/reader');error.diagnostic=safe;raise error
        if any(type(result.get(k)) is not int or result[k]!=0 for k in ('account_data_posts','authentication_posts')):raise ValueError('native_capture/runner')
        installed=result.get('installed')
        if not isinstance(installed,dict) or installed.get('bytes_match') is not True or not integer(installed.get('files'),1,1000):raise ValueError('native_capture/runner')
        return result
    finally:stop(child)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);access=parser.add_mutually_exclusive_group()
    access.add_argument('--saved-session',action='store_true');access.add_argument('--mock',action='store_true')
    parser.add_argument('--source-format',choices=('web_txt','web_xhtml'),default='web_txt')
    parser.add_argument('--capture',action='store_true');parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER)
    a=parser.parse_args(argv)
    if (a.saved_session or a.mock or a.capture or a.native_ui_command or a.source_format!='web_txt') and not ((a.saved_session or a.mock) and a.capture and a.native_ui_command):parser.error('explicit capture and private native command required')
    r=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,
           synthetic_only=a.mock,future_write_granted=False,private_data_on_regular_disk=False)
    web=api=saved=grant=session=server=None
    try:
        if a.saved_session or a.mock:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            if a.mock:
                from native_reader_fixture import NativeReaderServer,GRANT
                from test_secure_native_session import Backend
                from urllib.parse import urlsplit
                class Server(NativeReaderServer):
                    def route(self,method,target,data):
                        if urlsplit(target).hostname=='i.weread.qq.com' and urlsplit(target).path=='/book/info':
                            status,value=super().route(method,target,data);value['version']=7;return status,value
                        if urlsplit(target).hostname=='weread.qq.com' and urlsplit(target).path=='/web/shelf/sync':
                            status,value=super().route(method,target,data)
                            for row in value['books']:row['bookVersion']=7;row['version']=7
                            return status,value
                        if urlsplit(target).hostname=='weread.qq.com' and urlsplit(target).path=='/web/book/chapterInfos':
                            status,value=super().route(method,target,data)
                            for row in value['data']:row['book']={'bookId':row['bookId'],'bookVersion':7}
                            return status,value
                        return super().route(method,target,data)
                server=Server();server.content_format='txt' if a.source_format=='web_txt' else 'xhtml';threading.Thread(target=server.serve_forever,daemon=True).start();grant=deepcopy(GRANT)
                class MockSource(ReadingSource if a.source_format=='web_txt' else XhtmlSource):
                    def inspect_book(self,book_id,hint=None):return super().inspect_book(book_id,'txt')
                    def select_shelf_book(self):return ReadingPreflight.select_shelf_book(self)
                    def request(self,stage,url,body=None,**options):
                        status,value=server.route('POST' if body is not None else 'GET',url,body or {})[:2]
                        self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('native_capture/mock')
                        if a.source_format=='web_xhtml':
                            if stage in ('e_0','e_1','e_3'):self.shards[stage]=value
                            elif stage=='shelf':self.shelf_ids=[str(row['bookId']) for row in value['books']]
                            elif stage=='progress_before':self.baseline=reading_position(value,self.book_id)
                            if stage in ('catalog_before','catalog_after'):self.record,self.chapters=normalize_chapter_infos(value,self.book_id)
                        return json.dumps(value) if options.get('as_json') is False and not isinstance(value,str) else value
                class MockNative(Native):
                    def request(self,stage,url,body=None,credentials=None,timeout=15):
                        if body is not None or credentials!=grant:raise ValueError('native_capture/mock')
                        status,value=server.route('GET',url,{})[:2];self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('native_capture/mock')
                        return value
                chunks={}
                store=NativeCaptureStore(Backend(),chunk_backend=lambda index:chunks.setdefault(index,Backend()));web=MockSource();web.vid=grant['vid'];web.set_cookie('wr_vid',web.vid);web.set_cookie('wr_skey','mock_key');factory=MockNative
            else:
                store=NativeCaptureStore()
                if store.read()!=(None,None):raise ValueError('native_capture/already_captured')
                from verify_native_thought_trial import other_pending
                if other_pending():raise ValueError('native_capture/pending')
                session=SessionStore();saved=session.load();grant=NativeSessionStore().load(saved['vid']);web=(ReadingSource() if a.source_format=='web_txt' else XhtmlSource());web.vid=saved['vid']
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                factory=Native
            web.verify_account()
            if a.source_format=='web_txt':
                if not web.find_sample(limit=16):raise ValueError('native_capture/no_source')
                plan=web.inspect_plan();payload=None
            else:plan=None;payload=web.prepare()
            api=factory(grant,web.book_id)
            before=snapshot(web,api,grant,plan) if plan else xhtml_snapshot(web,api,grant)
            web.reader_shelf=web.request('shelf',WEB+'/web/shelf/sync');web_shelf=state_hash(web.reader_shelf)
            if plan:payload=reading_payload(web)
            payload.update(vid=web.vid,cookies={c.name:c.value for c in web.cookies},
                native_time_capture=dict(device_sha256=digest(grant['deviceId']),baseline_sha256=digest(before),book_version=before['version']))
            command=a.native_ui_command
            if server:
                payload['time_capture_mock_port']=server.server_port
                command=[str(server.server_port) if arg=='@MOCK_PORT@' else arg for arg in command]
            payload_valid(payload,server.server_port if server else None)
            output=execute(payload,command);captured=validate(output['capture'])
            if time.time()<captured['ended_at'] or time.time()-captured['ended_at']>30:raise ValueError('native_capture/stale')
            if (captured['owner']!=web.vid or captured['device_sha256']!=digest(grant['deviceId']) or captured['book_id']!=web.book_id
                    or captured['baseline_sha256']!=digest(before) or captured['chapter_uid']!=web.chapter or captured['book_version']!=before['version'] or captured['raw_sha256']!=before['source']):raise ValueError('native_capture/binding')
            for key,value in output['cookies'].items():web.set_cookie(key,value)
            # Re-fetch raw bytes in addition to a fresh catalogue and both positions.
            if plan:
                if not web.inspect_book(web.book_id,'txt'):raise ValueError('native_capture/source_changed')
                after_plan=web.inspect_plan()
                if snapshot(web,api,grant,after_plan)!=before or after_plan['baseline']!=plan['baseline']:raise ValueError('native_capture/changed')
            else:
                web.inspect(web.book_id)
                if xhtml_snapshot(web,api,grant)!=before:raise ValueError('native_capture/changed')
            if state_hash(web.request('shelf',WEB+'/web/shelf/sync'))!=web_shelf:raise ValueError('native_capture/shelf_changed')
            web.verify_account()
            if session:save_refreshed_web_session(session,saved,web)
            receipt=store.capture(captured)
            if store.read()[1]!=receipt:raise ValueError('native_capture/store')
            r.update(result='NATIVE_STATISTICS_WINDOW_CAPTURED',seconds=captured['seconds'],native_rows=len(captured['rows']),
                     native_statistics_and_sqlite=True,exact_epub_retained_in_keychain=not a.mock,
                     native_ui=output['native_capture'],installed=output['installed'],profile_removed=output['profile_removed'],
                     original_cloud_source_positions_counts_shelf_exact=True,
                     not_before_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(captured['not_before'])))
    except (Exception,KeyboardInterrupt) as error:
        r['result']='UNVERIFIED'
        if a.mock:r['synthetic_exception_type']=type(error).__name__
        if isinstance(error,ValueError) and re.fullmatch('native_capture/[a-z_]+',str(error)):r['reason']=str(error)
        if getattr(error,'diagnostic',None):r['diagnostic']=error.diagnostic
    finally:
        if web:
            r['web_stages']=[{k:row[k] for k in ('stage','status') if k in row} for row in web.report['stages']]
            web.sample=None
            if hasattr(web,'shards'):web.shards.clear()
            web.close()
        if api:r['native_stages']=[{k:row[k] for k in ('stage','status','error_code') if k in row} for row in api.report['stages']]
        if server:server.shutdown();server.server_close()
        for value in (saved,grant):
            if value:value.clear()
    print(json.dumps(r,indent=2));return int(r['result']=='UNVERIFIED')

if __name__=='__main__':raise SystemExit(main())
