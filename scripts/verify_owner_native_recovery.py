#!/usr/bin/env python3
"""Default offline. Explicit ReaderUI renewal after a fresh, independent 401.

No data write path. Grants travel in private pipes/tmpfs and macOS Keychain.
An uncertain authorization claim is never released or automatically replayed.
"""
import argparse
from copy import deepcopy
from datetime import datetime,timezone
import json
import os
from pathlib import Path
import resource
import secrets
import threading
from urllib.parse import urlsplit
from native_source_recovery_broker import Broker,execute
from native_source_recovery_fixture import NativeRecoveryServer
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_native_reader_trial import ReadingSource,reading_payload
from verify_native_txt_position import Native
from verify_raw_txt_excerpt import candidate
from verify_native_txt_roundtrip import source_hash
from verify_reader_progress import project,find_node
from verify_native_position_lua import equivalent
from shelf_flag_change_contract import state_hash
from readtime_upload_model import integer,guest_token,local_zone
from verify_translation_preflight import save_refreshed_web_session
from verify_eink_login import BASE


class RecoveryServer(NativeRecoveryServer):
    def __init__(self,expired=True):
        super().__init__();self.recovery_mode='snapshot';self.expired=expired
    def route(self,method,target,data):
        url=urlsplit(target)
        if (self.expired and not self.auth_posts and method=='GET' and url.hostname=='i.weread.qq.com' and url.path=='/book/info'):
            self.expiries+=1;return 401,dict(errcode=-1)
        if not self.expired and method=='GET' and url.hostname=='i.weread.qq.com' and url.path=='/book/info':
            from native_reader_fixture import NativeReaderServer
            return NativeReaderServer.route(self,method,target,data)
        return super().route(method,target,data)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);a=p.add_mutually_exclusive_group()
    a.add_argument('--saved-session',action='store_true');a.add_argument('--mock',action='store_true')
    p.add_argument('--no-expiry',action='store_true');p.add_argument('--once-marker',type=Path)
    p.add_argument('--observe-only',action='store_true',help='never grant an authorization request, even after a new 401')
    p.add_argument('--book-from-retired-close',action='store_true');p.add_argument('--native-ui-command',nargs=argparse.REMAINDER)
    args=p.parse_args(argv)
    if (bool(args.native_ui_command)!=bool(args.saved_session or args.mock) or args.no_expiry and not args.mock
            or args.saved_session and not args.once_marker or args.once_marker and not args.saved_session
            or args.book_from_retired_close and not args.saved_session
            or args.observe_only and not (args.saved_session or args.mock)):p.error('paired explicit session/runner and real once marker required')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts_claimed=0,blocked_data_posts=0,private_data_on_regular_disk=False)
    web=server=saved=session=grant=broker=None;reference=None;marker_claimed=False;native_stages=[];private_literals=set()
    try:
        if not (args.saved_session or args.mock):print(json.dumps(report,indent=2));return 0
        resource.setrlimit(resource.RLIMIT_CORE,(0,0));report['synthetic_only']=args.mock
        if args.mock:
            from native_reader_fixture import GRANT,BOOK_ID,chapter_txt
            from test_secure_native_session import Backend
            from txt_coordinates import PlainSource
            server=RecoveryServer(not args.no_expiry);threading.Thread(target=server.serve_forever,daemon=True).start()
            raw=chapter_txt(2);co=PlainSource(raw).locate('这是第2章的第1段。窗外的风穿过树梢')[0]
            server.progress[BOOK_ID].update(chapterOffset=co,summary=PlainSource(raw).excerpt(co)['text'])
            grant=deepcopy(GRANT);identity=BOOK_ID
            class MockSource(ReadingSource):
                def inspect_book(self,book_id,hint=None):return super().inspect_book(book_id,'txt' if book_id==BOOK_ID else hint)
                def request(self,stage,url,body=None,**options):
                    status,value=server.route('POST' if body is not None else 'GET',url,body or {})[:2]
                    self.report['stages'].append(dict(stage=stage,status=status))
                    if status!=200:raise ValueError('source_recovery/mock_response')
                    return json.dumps(value) if options.get('as_json') is False and not isinstance(value,str) else value
            web=MockSource();web.vid=grant['vid'];web.set_cookie('wr_vid',web.vid);web.set_cookie('wr_skey','mock_key')
            store=NativeSessionStore(Backend());store.save(grant,web.vid,verified=True)
        else:
            marker=args.once_marker
            if not marker.is_absolute() or marker.exists() or not marker.parent.is_dir():raise ValueError('source_recovery/consumed')
            from verify_native_thought_trial import other_pending
            if other_pending():raise ValueError('source_recovery/pending')
            session=SessionStore();saved=session.load();store=NativeSessionStore();grant=store.load(saved['vid']);identity=None
            if args.book_from_retired_close:
                from secure_native_close_trial import NativeCloseTrialStore
                reference=NativeCloseTrialStore().read();old=reference[0]
                if not old or old['phase']!='retired' or old['posts']!=2:raise ValueError('source_recovery/reference')
                identity=old['plan']['baseline']['book_id']
            web=ReadingSource();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
        private_literals.update(str(v) for v in grant.values())
        web.verify_account()
        if not web.find_sample(book_id=identity,limit=16):raise ValueError('source_recovery/no_source')
        before,target=candidate(web.sample['plain'],web.inspect_plan())
        private_literals.update((web.vid,web.book_id,before['summary'],target['summary']))
        web.reader_shelf=web.request('shelf','https://weread.qq.com/web/shelf/sync');shelf_before=state_hash(web.reader_shelf)
        if not args.mock:save_refreshed_web_session(session,saved,web);saved=session.load()
        cookies={c.name:c.value for c in web.cookies} if args.mock else dict(saved['cookies'])
        payload=reading_payload(web);payload.update(vid=web.vid,cookies=cookies,native_source_excerpt=True,native_grant=grant,
            native_recovery=dict(rpc_token=secrets.token_hex(16),baseline=before,target=target,time_zone=local_zone()))
        if server:payload['reader_mock_port']=server.server_port
        command=[str(server.server_port) if server and x=='@MOCK_PORT@' else x for x in args.native_ui_command]
        def read(stage,url,credentials):
            if server:
                status,value=server.route('GET',url,{})[:2];native_stages.append(dict(stage=stage,status=status))
                if status!=200:raise ValueError('source_recovery/read')
                return value
            probe=Native(credentials,web.book_id)
            try:return probe.request(stage,url,credentials=credentials)
            finally:native_stages.extend({k:r[k] for k in ('stage','status','error_code') if k in r} for r in probe.report['stages'])
        def expiry(url,credentials):
            try:read('independent_expiry',url,credentials)
            except Exception:return bool(native_stages and native_stages[-1]==dict(stage='independent_expiry',status=401))
            return False
        def observe(credentials):
            raw=read('recovery_position',BASE+'/book/getProgress?bookId='+web.book_id,credentials);v=project(raw,web.book_id,'native')
            point={k:v[k] for k in ('book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')};point['chapter_uid']=str(point['chapter_uid'])
            counts={k:find_node(raw,web.book_id)[k] for k in ('readingTime','recordReadingTime','ttsTime')}
            if any(not integer(n,0,2**53-1) for n in counts.values()):raise ValueError('source_recovery/counts')
            info=read('recovery_info',BASE+'/book/info?bookId='+web.book_id,credentials)
            versions=[info[k] for k in ('version','bookVersion') if k in info]
            if str(info.get('bookId'))!=web.book_id or not versions or any(not integer(n,0,2147483647) or n!=versions[0] for n in versions):raise ValueError('source_recovery/version')
            shelf=read('recovery_shelf',BASE+'/shelf/sync',credentials)
            guest,_=guest_token(read('recovery_feature',BASE+'/feature?synckey=0',credentials))
            return dict(point=point,counts=counts,version=versions[0],shelf_sha256=state_hash(shelf),guest=guest,book_count=len(shelf['books']))
        def current():
            if not args.mock and session.load()['vid']!=web.vid:raise ValueError('source_recovery/account_changed')
        def claim():
            nonlocal marker_claimed
            if args.mock:
                if marker_claimed:raise ValueError('source_recovery/consumed')
            else:
                fd=os.open(args.once_marker,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
                with os.fdopen(fd,'w') as stream:
                    json.dump(dict(state='claimed',authentication_post_limit=1,account_data_post_limit=0),stream);stream.flush();os.fsync(stream.fileno())
                directory_fd=os.open(args.once_marker.parent,os.O_RDONLY)
                try:os.fsync(directory_fd)
                finally:os.close(directory_fd)
            marker_claimed=True
        broker=Broker(payload,store,verify_expiry=expiry,observe=observe,current=current,claim=claim,allow_renewal=not args.observe_only)
        report['result']='UNVERIFIED';new_cookies=execute(payload,command,broker,report)
        for key,value in new_cookies.items():web.set_cookie(key,value)
        after=web.request('progress_after','https://weread.qq.com/web/book/getProgress?bookId='+web.book_id)
        observed=project(after,web.book_id);selected={k:observed[k] for k in before};selected['chapter_uid']=str(selected['chapter_uid'])
        if not equivalent(selected,before) or state_hash(web.request('shelf','https://weread.qq.com/web/shelf/sync'))!=shelf_before:
            raise ValueError('source_recovery/cloud_changed')
        if source_hash(web)!=payload['source_raw_sha256']:raise ValueError('source_recovery/source')
        if reference is not None and NativeCloseTrialStore().read()!=reference:raise ValueError('source_recovery/reference')
        report.update(web_original_position_summary_shelf_preserved=True,retired_reference_unchanged=reference is not None,
                      independent_http_401_observed=broker.posts==1)
        if server and (server.native_posts!=0 or server.auth_posts!=broker.posts or not server.preserved_counts()):raise ValueError('source_recovery/mock_writes')
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and __import__('re').fullmatch('source_recovery/[a-z_]+',str(error)):report['reason']=str(error)
    finally:
        if web:
            if not args.mock and web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:report['result']='UNVERIFIED'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.sample=None;web.close()
        report['native_stages']=native_stages
        if server:report.update(synthetic_data_posts=server.native_posts,synthetic_authentication_posts=server.auth_posts);server.shutdown();server.server_close()
        if saved:saved.clear()
        if broker and broker.fresh:private_literals.update(str(v) for v in broker.fresh.values())
        if grant:grant.clear()
        serialized=json.dumps(report,ensure_ascii=True)
        if any(len(value)>=8 and (value in serialized or json.dumps(value,ensure_ascii=True)[1:-1] in serialized) for value in private_literals):
            report=dict(result='UNVERIFIED',reason='source_recovery/report_privacy',account_data_posts=0,
                        authentication_posts_claimed=broker.posts if broker else 0,keychain_new_grant_saved=bool(broker and broker.fresh))
        if args.once_marker and marker_claimed:
            with args.once_marker.open('w') as stream:
                json.dump(dict(state='consumed',result=report['result'],authentication_post_limit=1,account_data_post_limit=0,
                               new_grant_saved=broker is not None and broker.fresh is not None),stream);stream.flush();os.fsync(stream.fileno())
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
