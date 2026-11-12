#!/usr/bin/env python3
"""One native ReaderUI first position. Offline unless explicitly paired; no restore."""
import argparse,json,re,resource,secrets,threading,time
from copy import deepcopy
from datetime import datetime,timezone
from secure_native_initial_reader import NativeInitialReaderStore
from native_initial_reader_model import PROTOCOL,validate_plan
from native_initial_reader_broker import execute
from native_initial_reader_contract import validate_payload
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from verify_owner_unstarted import Source
from verify_native_txt_position import Native
from verify_native_initial_position import metadata,observations,verify_source,check_binding,matches_target,observed_kind
from native_initial_position import no_chapter,counts
from source_remote_position import public_report,catalog_index
from verify_native_reader_trial import reading_payload
from verify_native_txt_roundtrip import source_hash,catalog_hash
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from txt_coordinates import PlainSource
from readtime_upload_model import guest_token,local_zone
from verify_eink_login import BASE
from verify_web_source_progress import BASE as WEB
from verify_translation_preflight import save_refreshed_web_session


class Reads(Native):max_reads=128


def before(web,api,grant,plan):
    verify_source(web,plan);check_binding(web,api,grant,plan)
    native,remote=observations(web,api,grant)
    if (dict(native=no_chapter(native,web.book_id),web=no_chapter(remote,web.book_id))!=plan['baseline']
            or counts(native,web.book_id)!=plan['counts']):raise ValueError('initial_reader/baseline_changed')


def after(web,api,grant,plan):
    verify_source(web,plan);check_binding(web,api,grant,plan)
    consecutive=0
    for attempt in range(1,6):
        native,remote=observations(web,api,grant);kind=observed_kind(native,web.book_id,plan)
        if kind=='target' and matches_target(remote,web.book_id,plan['target']):
            consecutive+=1
            if consecutive==2:return
        else:
            consecutive=0
            if not matches_target(remote,web.book_id,plan['target']) and no_chapter(remote,web.book_id)!=plan['baseline']['web']:
                raise ValueError('initial_reader/web_changed')
        if attempt<5:time.sleep(1)
    raise ValueError('initial_reader/readback')


def inspect_current(web,api,grant,plan,r):
    validate_plan(plan);verify_source(web,plan);check_binding(web,api,grant,plan,read_only=True)
    previous=None
    for _i in range(2):
        native,remote=observations(web,api,grant);kind=observed_kind(native,web.book_id,plan)
        other='target' if matches_target(remote,web.book_id,plan['target']) else 'original' if no_chapter(remote,web.book_id)==plan['baseline']['web'] else 'other'
        if kind!=other or previous is not None and kind!=previous:raise ValueError('initial_reader/inspection_changed')
        previous=kind
    r.update(result='NATIVE_INITIAL_READER_CURRENT_STATE_VERIFIED',current_state=previous,independent_observations=2)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);access=p.add_mutually_exclusive_group();access.add_argument('--saved-session',action='store_true');access.add_argument('--mock',action='store_true')
    mode=p.add_mutually_exclusive_group();mode.add_argument('--prepare',action='store_true');mode.add_argument('--dry-run',action='store_true');mode.add_argument('--apply',action='store_true');mode.add_argument('--inspect',action='store_true')
    p.add_argument('--mock-mode',choices=('accepted','noack','delayed','rejected','changed_counts'),default='accepted');p.add_argument('--native-ui-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    active=a.prepare or a.dry_run or a.apply or a.inspect
    if ((a.saved_session or a.mock or active or a.native_ui_command is not None) and not ((a.saved_session or a.mock) and active and (a.inspect and a.saved_session and a.native_ui_command is None or not a.inspect and a.native_ui_command))
            or a.mock_mode!='accepted' and not a.mock):p.error('explicit access, mode and private native reader required')
    r=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,
           private_data_on_regular_disk=False,synthetic_only=a.mock,original_no_chapter_restored=False)
    web=api=grant=saved=store=server=session=None;private_literals=set();phase='init'
    try:
        if a.saved_session or a.mock:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            if a.mock:
                from native_initial_fixture import NativeInitialServer
                from native_reader_fixture import GRANT,BOOK_ID
                from test_secure_native_session import Backend
                server=NativeInitialServer(a.mock_mode);threading.Thread(target=server.serve_forever,daemon=True).start();grant=deepcopy(GRANT)
                class MockSource(Source):
                    def inspect_book(self,book_id,hint=None):return super().inspect_book(book_id,'txt' if book_id==BOOK_ID else hint)
                    def request(self,stage,url,body=None,**options):
                        status,v=server.route('POST' if body is not None else 'GET',url,body or {})[:2];self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('initial_reader/mock_response')
                        return json.dumps(v) if options.get('as_json') is False and not isinstance(v,str) else v
                class MockReads(Reads):
                    def request(self,stage,url,body=None,credentials=None,timeout=15):
                        if body is not None or credentials!=grant:raise ValueError('initial_reader/mock_scope')
                        status,v=server.route('GET',url,{})[:2];self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('initial_reader/mock_response')
                        return v
                web=MockSource();web.vid=grant['vid'];web.set_cookie('wr_vid',web.vid);web.set_cookie('wr_skey','mock_key');store=NativeInitialReaderStore(Backend());native_factory=MockReads
            else:
                from verify_native_thought_trial import other_pending
                if other_pending(exclude_native_initial_reader=not a.prepare):raise ValueError('initial_reader/pending')
                session=SessionStore();saved=session.load();grant=NativeSessionStore().load(saved['vid']);web=Source();web.vid=saved['vid']
                for k,v in saved['cookies'].items():web.set_cookie(k,v)
                store=NativeInitialReaderStore();native_factory=Reads
            state,_receipt=store.read();private_literals.update(str(v) for v in grant.values());private_literals.add(web.vid)
            if a.prepare and state is not None:raise ValueError('initial_reader/consumed')
            if not a.prepare and not a.mock and (not state or not a.inspect and state['phase']!='prepared'):raise ValueError('initial_reader/intent')
            identity=state['plan']['target']['book_id'] if state else None;phase='source';web.verify_account()
            if a.inspect and state:web.choose_chapter=lambda rows:next(row|{'chapterUid':str(row['chapterUid'])} for row in rows if str(row.get('chapterUid'))==state['plan']['target']['chapter_uid'])
            if not web.find_sample(book_id=identity,limit=32):raise ValueError('initial_reader/no_source')
            api=native_factory(grant,web.book_id)
            if a.inspect:
                private_literals.update((web.book_id,state['plan']['target']['summary']));phase='inspection';inspect_current(web,api,grant,state['plan'],r)
            else:
                native,remote=observations(web,api,grant);baseline=dict(native=no_chapter(native,web.book_id),web=no_chapter(remote,web.book_id))
                before_counts=counts(native,web.book_id)
                if any(before_counts.values()):raise ValueError('initial_reader/existing_time')
                version=metadata(api,grant,web.book_id);web.reader_shelf=web.request('shelf',WEB+'/web/shelf/sync')
                if not a.mock:save_refreshed_web_session(session,saved,web);saved=session.load()
                cookies={c.name:c.value for c in web.cookies} if a.mock else saved['cookies'];payload=reading_payload(web)
                if state:plan=deepcopy(state['plan'])
                else:
                    target=dict(book_id=web.book_id,chapter_uid=web.chapter,chapter_idx=catalog_index(web.sample['chapters'],web.chapter),
                                chapter_offset=payload['source_sample_offset'],raw_percent=0,summary=PlainSource(web.sample['plain']).excerpt(payload['source_sample_offset'])['text'])
                    plan=dict(protocol=PROTOCOL,owner_sha256=digest(web.vid),grant_sha256=digest(grant),source_sha256=source_hash(web),catalog_sha256=catalog_hash(web),
                              shelf_sha256=state_hash(web.reader_shelf),native_shelf_sha256=state_hash(api.request('initial_position_shelf',BASE+'/shelf/sync',credentials=grant)),
                              source_file_id='0'*64,baseline=baseline,target=target,counts=before_counts,version=version)
                validate_plan(plan);private_literals.update((web.book_id,plan['target']['summary'],payload['source_text'],*cookies.values()))
                guest,_kind=guest_token(api.request('initial_position_feature',BASE+'/feature?synckey=0',credentials=grant))
                payload.update(vid=web.vid,cookies=cookies,native_source_excerpt=True,native_grant=grant)
                payload['native_initial_reader']=dict(plan=plan,armed=a.apply,bind_percent=not a.prepare,rpc_token=secrets.token_hex(16),native_shelf_sha256=plan['native_shelf_sha256'],guest=guest,time_zone=local_zone())
                command=list(a.native_ui_command)
                if server:payload['reader_mock_port']=server.server_port;command=[str(server.server_port) if x=='@MOCK_PORT@' else x for x in command]
                def current():
                    if not a.mock and (digest(NativeSessionStore().load(web.vid))!=plan['grant_sha256'] or SessionStore().load()['vid']!=web.vid):raise ValueError('initial_reader/grant')
                pre=lambda bound:before(web,api,grant,bound)
                post=lambda bound:after(web,api,grant,bound)
                phase='native_reader'
                if a.mock and not a.prepare:
                    dry=deepcopy(payload);dry['native_initial_reader'].update(armed=False,bind_percent=False,rpc_token=secrets.token_hex(16))
                    execute(dry,[x for x in command if x!='--armed'],store,{},prepare=True,current=current,before=pre,after=post)
                    payload['native_initial_reader']['plan']=store.read()[0]['plan']
                validate_payload(payload,a.apply,server.server_port if server else None)
                returned=execute(payload,command,store,r,prepare=a.prepare,current=current,before=pre,after=post)
                if not a.mock:
                    web.cookies.clear()
                    for k,v in returned.items():web.set_cookie(k,v)
                final=store.read()[0]['plan'];phase='final'
                if a.apply:post(final);r['source_catalog_counts_shelf_preserved']=True
                else:pre(final)
    except (Exception,KeyboardInterrupt) as error:
        r.update(result='UNVERIFIED',failure_stage=phase)
        if isinstance(error,ValueError) and re.fullmatch(r'(?:initial_reader|initial_position)/[a-z_]+',str(error)):r['reason']=str(error)
    finally:
        if web:
            if session and web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:r['result']='UNVERIFIED'
            r['web_stages']=[{k:x[k] for k in ('stage','status','api_code') if k in x} for x in web.report['stages']];web.sample=None;web.close()
        if api:r['native_stages']=[{k:x[k] for k in ('stage','status','error_code') if k in x} for x in api.report['stages']]
        if store:
            try:state,_receipt=store.read();r['intent_phase']=state['phase'] if state else 'absent';r['claimed_posts']=state['posts'] if state else 0
            except Exception:r['intent_phase']='unverified'
        if server:r['mock_server_posts']=server.native_posts;server.shutdown();server.server_close()
        for value in (saved,grant):
            if value:value.clear()
    public=public_report(r,private_literals)
    if public is not r:public.update(account_data_posts=r['account_data_posts'],intent_phase=r.get('intent_phase','unverified'),claimed_posts=r.get('claimed_posts',0))
    print(json.dumps(public,indent=2));return int(public['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
