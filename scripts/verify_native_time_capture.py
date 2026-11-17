#!/usr/bin/env python3
"""Read-only real-native dwell capture; saves immutable provenance in Keychain.

No historical dispatch, renewal, clock edits, or changes to older capture scopes.
"""
import argparse,json,re,resource,threading,time
from copy import deepcopy
from datetime import datetime,timezone
from native_time_capture import NativeCaptureStore,validate
from run_native_time_capture import payload_valid
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


def execute(payload,command):
    import subprocess
    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
    from native_trial_pipe import stop
    try:
        out,_err=child.communicate(json.dumps(payload,separators=(',',':')).encode(),timeout=220)
        if not isinstance(out,bytes) or len(out)>2*1024*1024 or out.count(FRAME)!=1:raise ValueError('native_capture/frame')
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
    parser.add_argument('--capture',action='store_true');parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER)
    a=parser.parse_args(argv)
    if (a.saved_session or a.mock or a.capture or a.native_ui_command) and not ((a.saved_session or a.mock) and a.capture and a.native_ui_command):parser.error('explicit capture and private native command required')
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
                server=Server();threading.Thread(target=server.serve_forever,daemon=True).start();grant=deepcopy(GRANT)
                class MockSource(ReadingSource):
                    def inspect_book(self,book_id,hint=None):return super().inspect_book(book_id,'txt')
                    def request(self,stage,url,body=None,**options):
                        status,value=server.route('POST' if body is not None else 'GET',url,body or {})[:2]
                        self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('native_capture/mock')
                        return json.dumps(value) if options.get('as_json') is False and not isinstance(value,str) else value
                class MockNative(Native):
                    def request(self,stage,url,body=None,credentials=None,timeout=15):
                        if body is not None or credentials!=grant:raise ValueError('native_capture/mock')
                        status,value=server.route('GET',url,{})[:2];self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('native_capture/mock')
                        return value
                store=NativeCaptureStore(Backend());web=MockSource();web.vid=grant['vid'];web.set_cookie('wr_vid',web.vid);web.set_cookie('wr_skey','mock_key');factory=MockNative
            else:
                store=NativeCaptureStore()
                if store.read()!=(None,None):raise ValueError('native_capture/already_captured')
                from verify_native_thought_trial import other_pending
                if other_pending():raise ValueError('native_capture/pending')
                session=SessionStore();saved=session.load();grant=NativeSessionStore().load(saved['vid']);web=ReadingSource();web.vid=saved['vid']
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                factory=Native
            web.verify_account()
            if not web.find_sample(limit=16):raise ValueError('native_capture/no_source')
            plan=web.inspect_plan();api=factory(grant,web.book_id);before=snapshot(web,api,grant,plan)
            web.reader_shelf=web.request('shelf',WEB+'/web/shelf/sync');web_shelf=state_hash(web.reader_shelf)
            payload=reading_payload(web);payload.update(vid=web.vid,cookies={c.name:c.value for c in web.cookies},
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
            if not web.inspect_book(web.book_id,'txt'):raise ValueError('native_capture/source_changed')
            after_plan=web.inspect_plan()
            if snapshot(web,api,grant,after_plan)!=before or after_plan['baseline']!=plan['baseline']:raise ValueError('native_capture/changed')
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
            web.sample=None;web.close()
        if api:r['native_stages']=[{k:row[k] for k in ('stage','status','error_code') if k in row} for row in api.report['stages']]
        if server:server.shutdown();server.server_close()
        for value in (saved,grant):
            if value:value.clear()
    print(json.dumps(r,indent=2));return int(r['result']=='UNVERIFIED')

if __name__=='__main__':raise SystemExit(main())
