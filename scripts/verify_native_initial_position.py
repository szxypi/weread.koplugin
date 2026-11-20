#!/usr/bin/env python3
"""One purposeful first cloud position, Python-only sender, no restore/replay."""
import argparse
from copy import deepcopy
from datetime import datetime,timezone
import json,resource,secrets,subprocess,time
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from secure_native_initial_position import NativeInitialPositionStore
from native_initial_position import no_chapter,counts,validate_plan,PROTOCOL
from verify_owner_unstarted import Source
from verify_txt_reading import TxtProbe
from verify_native_reader_trial import reading_payload
from verify_native_txt_roundtrip import source_hash,catalog_hash
from verify_native_txt_position import Native
from verify_eink_login import NativeProbe,BASE
from verify_web_source_progress import BASE as WEB
from verify_reader_progress import project,find_node
from verify_translation_preflight import save_refreshed_web_session
from txt_full_summary import digest
from readtime_upload_model import guest_token,local_zone,integer
from native_txt_read_model import body
from secure_native_txt_roundtrip import POINT_FIELDS
from shelf_flag_change_contract import state_hash,flags
from owner_initial_plan_contract import validate_payload,decode_runner,validate_private
from source_remote_position import public_report


class Probe(Native):
    max_reads=128
    def __init__(self,grant,book):super().__init__(grant,book);self.posts=0;self.claim=None;self.expected=None
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if body is None:return super().request(stage,url,credentials=credentials,timeout=timeout)
        if (stage!='initial_position_write' or url!=BASE+'/book/read' or self.posts or credentials!=self.credentials or not self.claim
                or digest(body)!=self.expected or not 0<=time.time()-body.get('timestamp',0)<=30):raise ValueError('initial_position/dispatch')
        self.claim();self.posts=1
        return NativeProbe.request(self,stage,url,body,credentials,timeout)


def metadata(api,grant,book):
    value=api.request('initial_position_info',BASE+'/book/info?bookId='+book,credentials=grant)
    versions=[value[k] for k in ('bookVersion','version') if k in value]
    if str(value.get('bookId'))!=book or not versions or any(not integer(v,0,2147483647) or v!=versions[0] for v in versions):raise ValueError('initial_position/version')
    return versions[0]


def observations(web,api,grant):
    book=web.book_id
    native=api.request('initial_position_progress',BASE+'/book/getProgress?bookId='+book,credentials=grant)
    remote=web.request('progress_after',WEB+'/web/book/getProgress?bookId='+book)
    return native,remote


def verify_source(web,plan):
    # A post-initialization refresh may no longer satisfy Source's no-chapter
    # selection rule. Fetch exactly the already chosen chapter, never a new one.
    old=web.choose_chapter
    web.choose_chapter=lambda rows:next(row|{'chapterUid':str(row['chapterUid'])} for row in rows if str(row.get('chapterUid'))==plan['target']['chapter_uid'])
    try:
        if not TxtProbe.inspect_book(web,plan['target']['book_id'],'txt'):raise ValueError('initial_position/source')
    finally:web.choose_chapter=old
    if source_hash(web)!=plan['source_sha256'] or catalog_hash(web)!=plan['catalog_sha256']:raise ValueError('initial_position/source')


def check_binding(web,api,grant,plan,*,read_only=False):
    if digest(web.vid)!=plan['owner_sha256'] or not read_only and digest(grant)!=plan['grant_sha256']:raise ValueError('initial_position/owner')
    if metadata(api,grant,web.book_id)!=plan['version']:raise ValueError('initial_position/version')
    record=web.sample['record'];versions=[v[k] for v in (record,record.get('book',{})) for k in ('bookVersion','version') if isinstance(v,dict) and v.get(k) is not None]
    if any(not integer(v,0,2147483647) or v!=plan['version'] for v in versions) or plan['version']>0 and not versions:raise ValueError('initial_position/source_version')
    shelf=web.request('shelf',WEB+'/web/shelf/sync')
    if state_hash(shelf)!=plan['shelf_sha256'] or plan['target']['book_id'] not in flags(shelf):raise ValueError('initial_position/shelf')
    shelf=api.request('initial_position_shelf',BASE+'/shelf/sync',credentials=grant)
    if state_hash(shelf)!=plan['native_shelf_sha256'] or plan['target']['book_id'] not in flags(shelf):raise ValueError('initial_position/shelf')


def matches_target(raw,book,target):
    p=project(raw,book);node=find_node(raw,book)
    return (all(str(p[k])==str(target[k]) for k in ('book_id','chapter_uid'))
            and all(p[k]==target[k] for k in POINT_FIELDS-{'book_id','chapter_uid'})
            and any(k in node for k in ('chapterIdx','chapterIndex','chapter_idx')) and node.get('summary')==target['summary'])


def success(value):
    return (isinstance(value,dict) and (value.get('succ') is True or type(value.get('succ')) is int and value['succ']==1)
            and all(k not in value or type(value[k]) is int and value[k]==0 for k in ('errcode','errCode')))


def observed_kind(raw,book,plan):
    if counts(raw,book)!=plan['counts']:raise ValueError('initial_position/counts_changed')
    if matches_target(raw,book,plan['target']):return 'target'
    try:
        if no_chapter(raw,book)==plan['baseline']['native']:return 'original'
    except (ValueError,RuntimeError):pass
    raise ValueError('initial_position/unknown_readback')


def run(web,api,grant,store,plan,guest,r,*,prepare=False,apply=False,current=None):
    validate_plan(plan);state,receipt=store.read()
    if prepare:
        if state is not None:raise ValueError('initial_position/consumed')
    elif not state or state['phase']!='prepared' or state['plan']!=plan:raise ValueError('initial_position/intent')
    verify_source(web,plan);check_binding(web,api,grant,plan)
    first=observations(web,api,grant)
    if {k:no_chapter(v,web.book_id) for k,v in zip(('native','web'),first)}!=plan['baseline'] or counts(first[0],web.book_id)!=plan['counts']:raise ValueError('initial_position/baseline_changed')
    if current:current()
    if prepare:store.reserve(plan);r['result']='NATIVE_INITIAL_POSITION_PREPARED';return
    r['result']='NATIVE_INITIAL_POSITION_DISARMED_VERIFIED'
    if not apply:return
    # Re-read just before the only claim. No late page/source or old receipt
    # can rebind a different target into this frozen scope.
    later=observations(web,api,grant)
    if {k:no_chapter(v,web.book_id) for k,v in zip(('native','web'),later)}!=plan['baseline'] or counts(later[0],web.book_id)!=plan['counts']:raise ValueError('initial_position/baseline_changed')
    value=body(grant,plan['target'],plan['version'],guest,int(time.time()),secrets.randbelow(1000),local_zone())
    def claim():
        nonlocal receipt
        if current:current()
        receipt=store.advance(receipt,'prepared','pending')
    api.claim=claim;api.expected=digest(value)
    ack=api.request('initial_position_write',BASE+'/book/read',body=value,credentials=grant)
    acknowledged=success(ack);r['explicit_success_receipt']=acknowledged
    if acknowledged:receipt=store.advance(receipt,'pending','acknowledged')
    for attempt in range(1,5 if acknowledged else 2):
        if attempt>1:time.sleep(1)
        native,remote=observations(web,api,grant)
        # Web can omit counters; position and presence are still independently
        # checked against the exact target, while Native owns counter proof.
        kind=observed_kind(native,web.book_id,plan)
        web_target=matches_target(remote,web.book_id,plan['target'])
        if not web_target and no_chapter(remote,web.book_id)!=plan['baseline']['web']:raise ValueError('initial_position/web_changed')
        r['readback_attempts']=attempt
        if kind=='target' and web_target:
            r['independent_target_readback']=True;break
    if not acknowledged or not r.get('independent_target_readback'):raise ValueError('initial_position/unconfirmed')
    verify_source(web,plan);check_binding(web,api,grant,plan)
    # A separate full final observation is required before retiring the slot.
    native,remote=observations(web,api,grant)
    if observed_kind(native,web.book_id,plan)!='target':raise ValueError('initial_position/final_changed')
    if not matches_target(remote,web.book_id,plan['target']):raise ValueError('initial_position/final_changed')
    if current:current()
    store.advance(receipt,'acknowledged','retired')
    r.update(result='NATIVE_INITIAL_POSITION_VERIFIED',source_catalog_counts_shelf_preserved=True,first_position_established=True,
             original_no_chapter_restored=False,no_automatic_replay=True,historical_time_rows=0)


def inspect_current(web,api,grant,plan,r):
    validate_plan(plan);verify_source(web,plan);check_binding(web,api,grant,plan,read_only=True)
    previous=None
    for _i in range(2):
        native,remote=observations(web,api,grant);kind=observed_kind(native,web.book_id,plan)
        web_kind='target' if matches_target(remote,web.book_id,plan['target']) else 'original' if no_chapter(remote,web.book_id)==plan['baseline']['web'] else 'other'
        if kind!=web_kind or previous is not None and previous!=kind:raise ValueError('initial_position/inspection_changed')
        previous=kind
    r.update(result='NATIVE_INITIAL_POSITION_CURRENT_STATE_VERIFIED',current_state=previous,independent_observations=2,no_automatic_replay=True)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);access=p.add_mutually_exclusive_group();access.add_argument('--saved-session',action='store_true');access.add_argument('--mock',action='store_true')
    mode=p.add_mutually_exclusive_group();mode.add_argument('--prepare',action='store_true');mode.add_argument('--dry-run',action='store_true');mode.add_argument('--apply',action='store_true');mode.add_argument('--inspect',action='store_true')
    p.add_argument('--mock-mode',choices=('accepted','noack','delayed','rejected','changed_counts'),default='accepted');p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    active=a.prepare or a.dry_run or a.apply or a.inspect
    if ((a.saved_session or a.mock or active or a.lua_command is not None) and not ((a.saved_session or a.mock) and active and (a.inspect and a.saved_session and a.lua_command is None or not a.inspect and a.lua_command))
            or a.mock_mode!='accepted' and not a.mock):p.error('explicit access, mode and private candidate reader required')
    r=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False,production_upload_enabled=False,synthetic_only=a.mock)
    web=api=grant=saved=store=server=None;private_literals=set();phase='init'
    try:
        if a.saved_session or a.mock:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            if a.mock:
                from native_initial_fixture import NativeInitialServer
                from native_reader_fixture import GRANT,BOOK_ID
                from test_secure_native_session import Backend
                from threading import Thread
                server=NativeInitialServer(a.mock_mode);Thread(target=server.serve_forever,daemon=True).start();grant=deepcopy(GRANT)
                class MockSource(Source):
                    def inspect_book(self,book_id,hint=None):return super().inspect_book(book_id,'txt' if book_id==BOOK_ID else hint)
                    def request(self,stage,url,body=None,**options):
                        status,v=server.route('POST' if body is not None else 'GET',url,body or {})[:2];self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('initial_position/mock_response')
                        return json.dumps(v) if options.get('as_json') is False and not isinstance(v,str) else v
                class MockProbe(Probe):
                    def request(self,stage,url,body=None,credentials=None,timeout=15):
                        if credentials!=grant:raise ValueError('initial_position/mock_scope')
                        if body is not None:
                            if self.posts or stage!='initial_position_write' or url!=BASE+'/book/read' or self.expected!=digest(body):raise ValueError('initial_position/dispatch')
                            self.claim();self.posts=1
                        status,v=server.route('POST' if body is not None else 'GET',url,body or {})[:2];self.report['stages'].append(dict(stage=stage,status=status))
                        if status!=200:raise ValueError('initial_position/mock_response')
                        return v
                web=MockSource();web.vid=grant['vid'];web.set_cookie('wr_vid',web.vid);web.set_cookie('wr_skey','mock_key');store=NativeInitialPositionStore(Backend());native_factory=MockProbe
            else:
                from verify_native_thought_trial import other_pending
                if other_pending(exclude_native_initial_position=not a.prepare):raise ValueError('initial_position/pending')
                session=SessionStore();saved=session.load();grant=NativeSessionStore().load(saved['vid']);web=Source();web.vid=saved['vid']
                for k,v in saved['cookies'].items():web.set_cookie(k,v)
                store=NativeInitialPositionStore();native_factory=Probe
            private_literals.update(str(v) for v in grant.values());private_literals.add(web.vid)
            state,_receipt=store.read()
            if a.prepare and state is not None:raise ValueError('initial_position/consumed')
            if not a.prepare and not a.mock and (not state or not a.inspect and state['phase']!='prepared'):raise ValueError('initial_position/intent')
            identity=state['plan']['target']['book_id'] if state else None
            phase='source';web.verify_account()
            if a.inspect and state:
                web.choose_chapter=lambda rows:next(row|{'chapterUid':str(row['chapterUid'])} for row in rows if str(row.get('chapterUid'))==state['plan']['target']['chapter_uid'])
            if not web.find_sample(book_id=identity,limit=32):raise ValueError('initial_position/no_source')
            api=native_factory(grant,web.book_id)
            if a.inspect:
                private_literals.update((web.book_id,state['plan']['target']['summary']))
                phase='inspection';inspect_current(web,api,grant,state['plan'],r)
            else:
                native,remote=observations(web,api,grant);baseline=dict(native=no_chapter(native,web.book_id),web=no_chapter(remote,web.book_id))
                before_counts=counts(native,web.book_id)
                if any(before_counts.values()):raise ValueError('initial_position/existing_time')
                version=metadata(api,grant,web.book_id);web.reader_shelf=web.request('shelf',WEB+'/web/shelf/sync')
                if not a.mock:save_refreshed_web_session(session,saved,web);saved=session.load()
                cookies={c.name:c.value for c in web.cookies} if a.mock else saved['cookies']
                payload=reading_payload(web);payload.update(vid=web.vid,cookies=cookies,native_source_excerpt=True,initial_plan_preview=True)
                if server:payload['initial_plan_mock_port']=server.server_port
                validate_payload(payload,server.server_port if server else None)
                command=[str(server.server_port) if server and x=='@MOCK_PORT@' else x for x in a.lua_command]
                phase='candidate';child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=240)
                v=decode_runner(child.stdout,web.vid);r['ui']=v['report']
                if child.returncode or v['report']['result']!='PASS':raise ValueError('initial_position/reader')
                candidate=v['candidate_private'][0];target=validate_private(candidate,payload,web.sample['plain'],web.sample['chapters'])
                private_literals.update((web.book_id,target['summary'],payload['source_text'],*cookies.values()))
                for k,value in v['cookies'].items():web.set_cookie(k,value)
                plan=dict(protocol=PROTOCOL,owner_sha256=digest(web.vid),grant_sha256=digest(grant),source_sha256=source_hash(web),catalog_sha256=catalog_hash(web),
                          shelf_sha256=state_hash(web.reader_shelf),native_shelf_sha256=state_hash(api.request('initial_position_shelf',BASE+'/shelf/sync',credentials=grant)),
                          source_file_id=candidate['source']['file_id'],baseline=baseline,target=target,counts=before_counts,version=version)
                validate_plan(plan)
                if state and state['plan']!=plan:raise ValueError('initial_position/plan_changed')
                guest,_kind=guest_token(api.request('initial_position_feature',BASE+'/feature?synckey=0',credentials=grant))
                def current():
                    if not a.mock and (NativeSessionStore().load(web.vid)!=grant or SessionStore().load()['vid']!=web.vid):raise ValueError('initial_position/grant')
                phase='protocol'
                if a.mock and not a.prepare:run(web,api,grant,store,plan,guest,{},prepare=True,current=current)
                run(web,api,grant,store,plan,guest,r,prepare=a.prepare,apply=a.apply,current=current)
    except (Exception,KeyboardInterrupt) as error:
        r.update(result='UNVERIFIED',failure_stage=phase)
        import re
        if isinstance(error,ValueError) and re.fullmatch('initial_position/[a-z_]+',str(error)):r['reason']=str(error)
    finally:
        if web:
            if not a.mock and web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:r['result']='UNVERIFIED'
            r['web_stages']=[{k:x[k] for k in ('stage','status','api_code') if k in x} for x in web.report['stages']];web.sample=None;web.close()
        if api:r['native_stages']=[{k:x[k] for k in ('stage','status','error_code') if k in x} for x in api.report['stages']];r['account_data_posts']=0 if a.mock else api.posts;r['synthetic_posts']=api.posts if a.mock else 0
        if store:
            try:state,_receipt=store.read();r['intent_phase']=state['phase'] if state else 'absent';r['claimed_posts']=state['posts'] if state else 0
            except Exception:r['intent_phase']='unverified'
        if server:r['mock_server_posts']=server.native_posts;server.shutdown();server.server_close()
        for value in (saved,grant):
            if value:value.clear()
    public=public_report(r,private_literals)
    if public is not r:
        public.update(account_data_posts=r['account_data_posts'],intent_phase=r.get('intent_phase','unverified'),claimed_posts=r.get('claimed_posts',0))
    r=public
    print(json.dumps(r,indent=2));return int(r['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
