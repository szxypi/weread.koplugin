#!/usr/bin/env python3
"""Real normal reader menus for an existing translation; no account mutations."""
import argparse,hashlib,json,resource,subprocess,threading
from datetime import datetime,timezone
from secure_weread_session import SessionStore,COOKIE_NAMES
from secure_native_session import NativeSessionStore
from secure_translation_generation import TranslationGenerationStore
from native_time_capture import NativeCaptureStore
from verify_translation_preflight import save_refreshed_web_session
from verify_translation_generation import Native,Web,position
from verify_reader_progress import find_node,identity
from native_initial_position import COUNTERS
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE
from verify_web_source_progress import BASE as WEB
from urllib.parse import urlencode
from run_translation_fetch_owner import payload_valid,validate_stage
from verify_owner_reading import validate_cookies

FRAME=b'\nWEREAD_TRANSLATION_OWNER_RUNNER='


def synthetic_source():
    return '<html><body><h1>Chapter One</h1>'+''.join('<p>Original paragraph '+str(i)+'. '+('Unique synthetic original sentence. '*8)+'</p><p class="wr-translation">译文段落 '+str(i)+'。'+('独立原生显示。'*8)+'</p>' for i in range(1,13))+'</body></html>'


def observation(raw,book,kind):
    """Read-only evidence only; missing progress/counters never become zeros."""
    try:node=find_node(raw,book)
    except ValueError as error:
        if str(error)!='progress_not_found':raise
        # Observed explicit unrecorded-book envelope. Do not admit arbitrary
        # empty/error responses or grant any upload/initialization capability.
        if (not isinstance(raw,dict) or set(raw)!={'bookId','book','canFreeRead','timestamp'}
                or identity(raw['bookId'])!=book or not isinstance(raw['book'],dict) or not raw['book']
                or 'bookId' in raw['book'] and identity(raw['book']['bookId'])!=book
                or type(raw['canFreeRead']) is not int or raw['canFreeRead'] not in (0,1)
                or type(raw['timestamp']) is not int or not 0<=raw['timestamp']<=2**53-1
                or len(json.dumps(raw).encode())>256*1024):raise ValueError('translation_owner/unknown_absence') from None
        counters={}
        def collect(value,path=()):
            if len(path)>8:raise ValueError('translation_owner/unknown_absence')
            if isinstance(value,dict):
                for key,item in value.items():
                    if key in COUNTERS:
                        if type(item) is not int or not 0<=item<=2**53-1:raise ValueError('translation_owner/counters')
                        counters[json.dumps(path+(key,),separators=(',',':'))]=item
                    collect(item,path+(key,))
            elif isinstance(value,list):
                for index,item in enumerate(value):collect(item,path+(index,))
        collect(raw['book'])
        return dict(position_present=False,book=raw['book'],can_free_read=raw['canFreeRead'],counters=counters)
    counters={k:node[k] for k in COUNTERS if k in node}
    if any(type(v) is not int or not 0<=v<=2**53-1 for v in counters.values()):raise ValueError('translation_owner/counters')
    return dict(position_present=True,position=position(raw,book,kind),counters=counters)


def snapshot(api,web,grant):
    book=web.book_id
    native=api.request('progress',BASE+'/book/getProgress?'+urlencode(dict(bookId=book)),credentials=grant)
    remote=web.request('progress',WEB+'/web/book/getProgress?'+urlencode(dict(bookId=book)))
    return dict(native=observation(native,book,'native'),web=observation(remote,book,'web'),
        native_shelf=state_hash(api.request('shelf',BASE+'/shelf/sync',credentials=grant)),
        web_shelf=state_hash(web.request('generation_shelf',WEB+'/web/shelf/sync')))


def execute(command,payload):
    child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode(),capture_output=True,timeout=360)
    if len(child.stdout)>1024*1024 or child.stdout.count(FRAME)!=1:raise ValueError('translation_owner/frame')
    value=json.loads(child.stdout.split(FRAME)[1])
    if not isinstance(value,dict):raise ValueError('translation_owner/frame')
    if child.returncode or value.get('result')!='PASS' or value.get('profile_removed') is not True:
        error=ValueError('translation_owner/reader');error.diagnostic={}
        if value.get('phase') in ('input','prepare','reader','download','copy','audit','complete','other'):error.diagnostic['phase']=value['phase']
        if type(value.get('failed_line')) is int and 0<=value['failed_line']<=10000:error.diagnostic['failed_line']=value['failed_line']
        raise error
    fields={'result','stages','profile_removed','cookies','account_data_posts','authentication_posts','installed'}
    if (set(value)!=fields or not isinstance(value['stages'],list) or len(value['stages'])!=2
            or any(type(value[k]) is not int or value[k]!=0 for k in ('account_data_posts','authentication_posts'))
            or not isinstance(value['installed'],dict) or set(value['installed'])!={'files','bytes_match'}
            or type(value['installed']['files']) is not int or not 1<=value['installed']['files']<=1000
            or value['installed']['bytes_match'] is not True):raise ValueError('translation_owner/stages')
    for stage,mode in zip(value['stages'],('live','reopen')):validate_stage(stage,mode)
    validate_cookies(value['cookies'],payload['vid'])
    return value


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);access=p.add_mutually_exclusive_group();access.add_argument('--saved-session',action='store_true');access.add_argument('--mock',action='store_true')
    p.add_argument('--native-ui-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if bool(a.saved_session or a.mock)!=bool(a.native_ui_command):p.error('explicit access and private native UI command required')
    r=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),synthetic_only=a.mock,account_data_posts=0,
        authentication_posts=0,generation_requests=0,translation_mode_requests=0,real_screenshots=0,private_data_on_regular_disk=False)
    api=web=saved=grant=server=None;phase='init'
    try:
        if a.saved_session or a.mock:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));command=list(a.native_ui_command)
            if a.mock:
                from mock_weread import MockServer
                server=MockServer(0);server.chapter_source=lambda uid,revision=None:synthetic_source()
                threading.Thread(target=server.serve_forever,daemon=True).start()
                raw=synthetic_source();payload=dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key'),book_id='900001',chapter_uid='1',
                    title='Synthetic translation acceptance',author='Synthetic',source=raw,source_sha256=hashlib.sha256(raw.encode()).hexdigest(),blocks=12,mock_port=server.server_port)
                command+=['--mock-port',str(server.server_port)]
            else:
                capture=NativeCaptureStore();generation=TranslationGenerationStore();retained=(capture.read(),generation.read())
                saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid']);api=Native();phase='discover';api.inspect(grant,1,True)
                sample=api.samples[0];web=Web();web.vid=saved['vid']
                for k,v in saved['cookies'].items():web.set_cookie(k,v)
                web.verify_account();phase='source';content=web.inspect_content(sample);source=web.content_sample
                if not source or content.get('nonempty_translation_blocks',0)<1:raise ValueError('translation_owner/no_existing_content')
                phase='baseline';baseline=snapshot(api,web,grant)
                payload=dict(vid=saved['vid'],cookies={c.name:c.value for c in web.cookies if c.name in COOKIE_NAMES
                    and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'},book_id=source['book_id'],chapter_uid=str(source['chapter_uid']),
                    title=sample['info'].get('title',''),author=sample['info'].get('author') or '',source=source['source'],
                    source_sha256=hashlib.sha256(source['source'].encode()).hexdigest(),blocks=content['nonempty_translation_blocks'])
            payload_valid(payload,server.server_port if server else None)
            phase='native';result=execute(command,payload)
            r.update(native_stages=result['stages'],installed=result['installed'],profile_removed=result['profile_removed'])
            if a.saved_session:
                validate_cookies(result['cookies'],saved['vid'])
                for k,v in result['cookies'].items():web.set_cookie(k,v)
                phase='final_snapshot'
                if snapshot(api,web,grant)!=baseline:raise ValueError('translation_owner/cloud_changed')
                web.inspect_content(sample,source['chapter_uid'])
                if web.content_sample['source']!=payload['source']:raise ValueError('translation_owner/source_changed')
                web.verify_account();save_refreshed_web_session(SessionStore(),saved,web)
                if (capture.read(),generation.read())!=retained or NativeSessionStore().load(saved['vid'])!=grant:raise ValueError('translation_owner/scope_changed')
                r.update(cloud_position_presence_and_shelf_unchanged=True,reported_counter_values_and_presence_unchanged=True,
                    cloud_position_present={k:baseline[k]['position_present'] for k in ('native','web')},
                    cloud_counter_fields_reported={k:len(baseline[k]['counters']) for k in ('native','web')},
                    source_exact_before_after=True,capture_and_generation_scopes_unchanged=True)
            r['result']='PASS_TRANSLATION_OWNER_NATIVE_UI'
    except Exception as error:
        r.update(result='UNVERIFIED',phase=phase)
        if str(error) in ('initial_position/counts','progress_not_found','progress_ambiguous','progress_invalid',
                'progress_book_mismatch','progress_rejected','translation_owner/cloud_changed','translation_owner/source_changed',
                'translation_owner/scope_changed','translation_owner/no_existing_content','translation_owner/unknown_absence',
                'translation_owner/counters'):r['reason']=str(error)
        if hasattr(error,'diagnostic'):r['diagnostic']=error.diagnostic
    finally:
        if api:r['native_stages_before_after']=[{k:v[k] for k in ('stage','status','error_code') if k in v} for v in api.report['stages']]
        if web:
            r['web_stages_before_after']=[{k:v[k] for k in ('stage','status','api_code') if k in v} for v in web.report['stages']];web.close()
        if server:server.shutdown();server.server_close()
        for value in (saved,grant):
            if value:value.clear()
    print(json.dumps(r,ensure_ascii=False,indent=2));return int(r['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
