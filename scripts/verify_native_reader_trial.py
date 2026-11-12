#!/usr/bin/env python3
"""ReaderUI manual advance plus exact service restore, with a new two-slot grant.

Offline by default. --prepare blocks HTTP dispatch and binds the actual reader
percent in Keychain. --apply only consumes that prepared scope, never replays.
"""
import argparse
from copy import deepcopy
from datetime import datetime,timezone
import json
import resource
import secrets
import threading
from secure_native_reader_trial import NativeReaderTrialStore,validate_plan
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from verify_native_txt_position import Source,Native
from verify_native_txt_roundtrip import source_hash,catalog_hash,check,run as recover,Probe as RecoveryProbe
from verify_raw_txt_excerpt import candidate
from verify_reader_progress import project,find_node
from verify_position_roundtrip import same_position
from verify_eink_login import BASE
from verify_web_source_progress import BASE as WEB
from verify_translation_preflight import save_refreshed_web_session
from verify_cb_progress import cb_id
from txt_coordinates import PlainSource
from txt_full_summary import digest
from shelf_flag_change_contract import state_hash
from readtime_upload_model import local_zone,guest_token,integer
from native_reader_trial_broker import execute


class Reads(Native):max_reads=128


class ReadingSource(Source):
    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage=='shelf':self.display_ids=[row['bookId'] for row in value['books'] if isinstance(row,dict) and cb_id(row.get('bookId'))]
        return value


def prepare_plan(web,native,credentials):
    source=web.inspect_plan();before,target=candidate(web.sample['plain'],source)
    raw=native.request('reader_trial_progress',BASE+'/book/getProgress?bookId='+web.book_id,credentials=credentials)
    node=find_node(raw,web.book_id);observed=project(raw,web.book_id,'native')
    if not same_position(observed,before) or node.get('summary')!=before['summary']:raise ValueError('reader_trial/baseline')
    counts={k:node.get(k) for k in ('readingTime','recordReadingTime','ttsTime')}
    if any(not integer(n,0,2**53-1) for n in counts.values()):raise ValueError('reader_trial/counts')
    info=native.request('reader_trial_info',BASE+'/book/info?bookId='+web.book_id,credentials=credentials)
    versions=[info[k] for k in ('bookVersion','version') if k in info]
    if (str(info.get('bookId'))!=web.book_id or not versions or any(not integer(n,0,2147483647) or n!=versions[0] for n in versions)
            or node.get('chapterProgress') is not None):raise ValueError('reader_trial/version')
    native_shelf=native.request('reader_trial_shelf',BASE+'/shelf/sync',credentials=credentials)
    guest,_kind=guest_token(native.request('reader_trial_feature',BASE+'/feature?synckey=0',credentials=credentials))
    web.reader_shelf=web.request('shelf',WEB+'/web/shelf/sync')
    # The unbound placeholder is replaced only by an observed ReaderUI plan,
    # before a prepared scope exists. Apply cannot change this percentage.
    target['raw_percent']=int(target['raw_percent'])
    plan=dict(protocol=NativeReaderTrialStore.protocol,owner_sha256=digest(web.vid),source_sha256=source_hash(web),catalog_sha256=catalog_hash(web),
              grant_sha256=digest(credentials),shelf_sha256=state_hash(web.reader_shelf),baseline=before,target=target,
              counts=counts,version=versions[0],chapter_progress=None)
    validate_plan(plan);return plan,state_hash(native_shelf),guest


def reading_payload(web):
    import re
    raw=web.sample['plain'];lines=[' '.join(line.split()) for line in raw.replace('\r\n','\n').replace('\r','\n').split('\n')]
    text=next(line[:32] for line in lines if len(line)>=32)
    rows=web.reader_shelf.get('books')
    if not isinstance(rows,list) or not 1<=len(rows)<=5000:raise ValueError('reader_trial/shelf')
    ids=list(dict.fromkeys(row['bookId'] for row in rows if isinstance(row,dict) and isinstance(row.get('bookId'),str)
                           and re.fullmatch(r'(?:[1-9][0-9]{0,19}|CB_[A-Za-z0-9]{1,64})',row['bookId'])))
    if web.book_id not in ids:raise ValueError('reader_trial/shelf')
    return dict(book_id=web.book_id,chapter_uid=web.chapter,source_text=text,source_format='web_txt',source_raw_sha256=source_hash(web),
                source_sample_offset=PlainSource(raw).locate(text)[0],shelf_ids=ids,shelf_books=len(rows))


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);access=p.add_mutually_exclusive_group();access.add_argument('--saved-session',action='store_true');access.add_argument('--mock',action='store_true')
    modes=p.add_mutually_exclusive_group();modes.add_argument('--prepare',action='store_true');modes.add_argument('--dry-run',action='store_true');modes.add_argument('--apply',action='store_true');modes.add_argument('--resolve',action='store_true');modes.add_argument('--restore-only',action='store_true')
    p.add_argument('--native-ui-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    active=a.prepare or a.dry_run or a.apply or a.resolve or a.restore_only
    if (a.saved_session and not active or active and not (a.saved_session or a.mock)
            or a.native_ui_command is not None and not (a.prepare or a.dry_run or a.apply)
            or (a.prepare or a.dry_run or a.apply) and not a.native_ui_command
            or (a.resolve or a.restore_only) and (not a.saved_session or a.native_ui_command)
            or a.mock and not (a.prepare or a.dry_run or a.apply)):p.error('paired saved/native mode required')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,
                web_write_posts=0,historical_time_rows=0,private_data_on_regular_disk=False,real_reader_roundtrip_verified=False)
    web=native=credentials=saved=store=server=session=payload=None
    try:
        if a.saved_session or a.mock:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            if a.mock:
                from native_reader_fixture import NativeReaderServer,GRANT,BOOK_ID,chapter_txt
                from test_secure_native_session import Backend
                server=NativeReaderServer();threading.Thread(target=server.serve_forever,daemon=True).start()
                raw=chapter_txt(2);co=PlainSource(raw).locate('这是第2章的第1段。窗外的风穿过树梢')[0]
                server.progress[BOOK_ID].update(chapterOffset=co,summary=PlainSource(raw).excerpt(co)['text'])
                credentials=deepcopy(GRANT)
                class MockSource(ReadingSource):
                    def inspect_book(self,book_id,hint=None):
                        return super().inspect_book(book_id,'txt' if book_id==BOOK_ID else hint)
                    def request(self,stage,url,body=None,**options):
                        status,value=server.route('POST' if body is not None else 'GET',url,body or {})[:2]
                        self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('reader_trial/mock_response')
                        if options.get('as_json') is False and not isinstance(value,str):return json.dumps(value)
                        return value
                web=MockSource();web.vid=GRANT['vid'];web.set_cookie('wr_vid',web.vid);web.set_cookie('wr_skey','mock_key')
                class MockReads(Reads):
                    def request(self,stage,url,body=None,credentials=None,timeout=15):
                        if body is not None or credentials!=self.credentials:raise ValueError('reader_trial/mock_scope')
                        status,value=server.route('GET',url,{})[:2];self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('reader_trial/mock_response')
                        return value
                store=NativeReaderTrialStore(Backend());native_factory=MockReads
            else:
                from verify_native_thought_trial import other_pending
                if other_pending(exclude_native_reader_trial=not a.prepare):raise ValueError('reader_trial/pending')
                session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                web=ReadingSource();web.vid=saved['vid']
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                store=NativeReaderTrialStore();native_factory=Reads
            state,_receipt=store.read()
            if a.prepare and state is not None:raise ValueError('reader_trial/consumed')
            if not a.prepare and not a.mock and not state:raise ValueError('reader_trial/no_intent')
            identity=state['plan']['baseline']['book_id'] if state else None
            web.verify_account()
            if not web.find_sample(book_id=identity,limit=16):raise ValueError('reader_trial/no_source')
            native=native_factory(credentials,web.book_id)
            if a.resolve or a.restore_only:
                if a.restore_only:native=RecoveryProbe(credentials,web.book_id,restore_only=True)
                recover(web,native,credentials,session,saved,store,report,resolving=a.resolve,restore_only=a.restore_only,
                        summary_method='literal_raw30_reader_viewport_percent')
            else:
                plan,native_shelf_hash,guest=prepare_plan(web,native,credentials)
                if state:
                    plan['target']['raw_percent']=state['plan']['target']['raw_percent']
                    if state['phase']!='prepared' or state['plan']!=plan:raise ValueError('reader_trial/stale_intent')
                if not a.mock:
                    web.verify_account();save_refreshed_web_session(session,saved,web);saved=session.load()
                cookies={c.name:c.value for c in web.cookies} if a.mock else dict(saved['cookies'])
                payload=reading_payload(web);payload.update(vid=web.vid,cookies=cookies,native_source_excerpt=True,native_grant=credentials)
                payload['native_reader_trial']=dict(plan=plan,armed=a.apply,bind_percent=not a.prepare,rpc_token=secrets.token_hex(16),
                                                   native_shelf_sha256=native_shelf_hash,guest=guest,time_zone=local_zone())
                command=list(a.native_ui_command or [])
                if a.mock:
                    payload['reader_mock_port']=server.server_port
                    command=[str(server.server_port) if x=='@MOCK_PORT@' else x for x in command]
                def current():
                    if not a.mock and (digest(NativeSessionStore().load(web.vid))!=plan['grant_sha256'] or SessionStore().load()['vid']!=web.vid):raise ValueError('reader_trial/grant')
                def before(seq,bound):check(web,native,credentials,bound,bound['baseline' if seq==1 else 'target'])
                def after(seq,bound):
                    expected=bound['target' if seq==1 else 'baseline']
                    check(web,native,credentials,bound,expected,refresh=True);check(web,native,credentials,bound,expected)
                if a.mock and not a.prepare:
                    dry=deepcopy(payload);dry['native_reader_trial'].update(armed=False,bind_percent=False,rpc_token=secrets.token_hex(16))
                    execute(dry,[x for x in command if x!='--armed'],store,{},prepare=True,current=current,before=before,after=after)
                    payload['native_reader_trial']['plan']=store.read()[0]['plan']
                returned=execute(payload,command,store,report,prepare=a.prepare,current=current,before=before,after=after)
                if not a.mock:
                    web.cookies.clear()
                    for key,value in returned.items():web.set_cookie(key,value)
                final_plan=store.read()[0]['plan']
                check(web,native,credentials,final_plan,final_plan['baseline'],refresh=True)
                if a.apply and not a.mock:report['real_reader_roundtrip_verified']=True
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        import re
        if isinstance(error,ValueError) and re.fullmatch(r'(?:reader_trial|native_txt|txt_roundtrip)/[a-z_]+',str(error)):report['reason']=str(error)
    finally:
        if web:
            if session and web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:report['result']='UNVERIFIED'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.sample=None;web.close()
        if native:
            if hasattr(native,'posts'):report['account_data_posts']=native.posts
            report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in native.report['stages']]
        if store:
            try:state,_receipt=store.read();report['intent_phase']=state['phase'] if state else 'absent';report['claimed_posts']=state['posts'] if state else 0
            except Exception:report['intent_phase']='unverified'
        if server:report['mock_server_posts']=server.native_posts;server.shutdown();server.server_close()
        for value in (saved,credentials,payload):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
