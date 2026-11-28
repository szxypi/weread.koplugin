#!/usr/bin/env python3
"""Real normal reader menus for an existing translation; no account mutations."""
import argparse,hashlib,json,resource,subprocess,threading
from datetime import datetime,timezone
from secure_weread_session import SessionStore,COOKIE_NAMES
from secure_native_session import NativeSessionStore
from secure_translation_generation import TranslationGenerationStore
from native_time_capture import NativeCaptureStore
from verify_translation_preflight import save_refreshed_web_session,PUBLIC_QUERIES,content_summary
from verify_translation_generation import Native,Web
from translation_observation import observation
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE
from verify_web_source_progress import BASE as WEB
from urllib.parse import urlencode
from run_translation_fetch_owner import payload_valid,validate_stage
from verify_owner_reading import validate_cookies
from translation_owner_excerpt import original_excerpt
from verify_reader_context import project as reader_context
from fetch_weread_epub import reader_url_for,make_content_params,decode_content_shards

FRAME=b'\nWEREAD_TRANSLATION_OWNER_RUNNER='


def synthetic_source():
    return '<html><body><h1>Chapter One</h1>'+''.join('<p>Original paragraph '+str(i)+'. '+('Unique synthetic original sentence. '*8)+'</p><p class="wr-translation">译文段落 '+str(i)+'。'+('独立原生显示。'*8)+'</p>' for i in range(1,13))+'</body></html>'


def member_source(web,sample,uid,paying):
    # Membership permits a normal read attempt; only actual decoded content is
    # accepted. A positive membership flag alone never proves chapter access.
    model=sample['expected'];matches=[row for row in model['chapters'] if row['uid']==uid]
    if (paying is not True or len(matches)!=1 or type(uid) is not int or not 0<uid<=2147483647
            or matches[0].get('wordCount',0)<=0):raise ValueError('translation_owner/member_scope')
    web.book_id=sample['book_id'];web.chapter=str(uid)
    html=web.request('reader',reader_url_for(web.book_id,web.chapter),as_json=False)
    state=reader_context(dict(book_id=web.book_id),html)
    if str(state['current_chapter'].get('chapterUid'))!=web.chapter:raise ValueError('translation_owner/member_scope')
    web.fields=make_content_params(web.book_id,web.chapter,state['psvts'],sc=1)
    parts=[web.request(stage,WEB+'/web/book/chapter/'+stage,web.fields,as_json=False) for stage in ('e_0','e_1','e_3')]
    raw=decode_content_shards(*parts)
    summary=content_summary(raw)
    return dict(book_id=web.book_id,chapter_uid=uid,source=raw),summary


def readable_catalog(sample):
    model=sample['expected'];source=sample['source'].get('data')
    records=[row for row in source if isinstance(row,dict) and str(row.get('bookId'))==sample['book_id']] if isinstance(source,list) else []
    if len(records)!=1 or not isinstance(records[0].get('updated'),list):raise ValueError('translation_owner/member_scope')
    raw=records[0]['updated'];rows=model['chapters']
    if len(raw)!=len(rows):raise ValueError('translation_owner/member_scope')
    selected=[]
    for original,row in zip(raw,rows):
        if str(original.get('chapterUid'))!=str(row['uid']):raise ValueError('translation_owner/member_scope')
        if row.get('wordCount',0)>0 and original.get('title')!='封面':selected.append(row)
    if not 2<=len(selected)<=15 or any(not 0<x['uid']<=2147483647 for x in selected):raise ValueError('translation_owner/member_scope')
    return selected

def snapshot(api,web,grant):
    book=web.book_id
    native=api.request('progress',BASE+'/book/getProgress?'+urlencode(dict(bookId=book)),credentials=grant)
    remote=web.request('progress',WEB+'/web/book/getProgress?'+urlencode(dict(bookId=book)))
    return dict(native=observation(native,book,'native'),web=observation(remote,book,'web'),
        native_shelf=state_hash(api.request('shelf',BASE+'/shelf/sync',credentials=grant)),
        web_shelf=state_hash(web.request('generation_shelf',WEB+'/web/shelf/sync')))


def execute(command,payload,annotations=False,range_mode=False,full_mode=False):
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
    for stage,mode in zip(value['stages'],('live','reopen')):validate_stage(stage,mode,annotations,range_mode,full_mode)
    validate_cookies(value['cookies'],payload['vid'])
    return value


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);access=p.add_mutually_exclusive_group();access.add_argument('--saved-session',action='store_true');access.add_argument('--mock',action='store_true')
    p.add_argument('--annotations',action='store_true');p.add_argument('--range',action='store_true');p.add_argument('--full',action='store_true')
    p.add_argument('--native-ui-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if sum((a.range,a.full,a.annotations))>1:p.error('select one acceptance scenario')
    if bool(a.saved_session or a.mock)!=bool(a.native_ui_command):p.error('explicit access and private native UI command required')
    r=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),synthetic_only=a.mock,annotation_test=a.annotations,range_test=a.range,full_test=a.full,account_data_posts=0,
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
                if a.range or a.full:
                    ids=['1','2','3'] if a.range else [str(i) for i in range(1,7)]
                    payload.update(chapter_uids=ids,source_hashes=[payload['source_sha256']]*len(ids),block_counts=[12]*len(ids))
                command+=['--mock-port',str(server.server_port)]
            else:
                capture=NativeCaptureStore();generation=TranslationGenerationStore();retained=(capture.read(),generation.read())
                saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid']);api=Native(public_query=PUBLIC_QUERIES[18] if a.full else PUBLIC_QUERIES[0]);phase='discover';api.inspect(grant,2 if a.range else 1,True)
                sample=api.samples[0];web=Web();web.vid=saved['vid']
                for k,v in saved['cookies'].items():web.set_cookie(k,v)
                web.verify_account();phase='source'
                if a.full:
                    selected=readable_catalog(sample);sources=[];summaries=[]
                    for row in selected:
                        item,summary=member_source(web,sample,row['uid'],api.member['paying']);sources.append(item);summaries.append(summary)
                    source=sources[0];content=summaries[0]
                    if not content['nonempty_translation_blocks']:raise ValueError('translation_owner/no_existing_content')
                elif a.range:
                    chosen=None
                    for candidate in api.samples:
                        rows=candidate['expected']['chapters']
                        runs=[rows[i:i+3] for i in range(len(rows)-2) if all(x['uid']>0 and x.get('wordCount',0)>=200 and x['free_or_owned'] for x in rows[i:i+3])]
                        for chunk in runs[:2]:
                            sources=[];summaries=[]
                            for row in chunk:
                                summary=web.inspect_content(candidate,row['uid']);item=web.content_sample
                                if not item or not summary.get('nonempty_translation_blocks') or summary.get('attempts',[{}])[-1].get('representation')!='download':break
                                sources.append(item);summaries.append(summary)
                            if len(sources)==3 and 200<=len(sources[0]['source'].encode())<=200*1024:
                                chosen=(candidate,sources,summaries);break
                        if chosen:break
                    if not chosen:raise ValueError('translation_owner/no_range_content')
                    sample,sources,summaries=chosen;source=sources[0];content=summaries[0]
                else:
                    content=web.inspect_content(sample);source=web.content_sample
                if not source or content.get('nonempty_translation_blocks',0)<1:raise ValueError('translation_owner/no_existing_content')
                phase='baseline';baseline=snapshot(api,web,grant)
                payload=dict(vid=saved['vid'],cookies={c.name:c.value for c in web.cookies if c.name in COOKIE_NAMES
                    and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'},book_id=source['book_id'],chapter_uid=str(source['chapter_uid']),
                    title=sample['info'].get('title',''),author=sample['info'].get('author') or '',source=source['source'],
                    source_sha256=hashlib.sha256(source['source'].encode()).hexdigest(),blocks=content['nonempty_translation_blocks'])
            if (a.range or a.full) and not a.mock:
                payload.update(chapter_uids=[str(x['chapter_uid']) for x in sources],source_hashes=[hashlib.sha256(x['source'].encode()).hexdigest() for x in sources],block_counts=[x['nonempty_translation_blocks'] for x in summaries])
            if a.range:command+=['--range']
            if a.full:command+=['--full']
            if a.annotations:
                payload['original_source']=original_excerpt(payload['source']);command+=['--annotations']
            payload_valid(payload,server.server_port if server else None,a.annotations,a.range,a.full)
            phase='native';result=execute(command,payload,a.annotations,a.range,a.full)
            r.update(native_stages=result['stages'],installed=result['installed'],profile_removed=result['profile_removed'])
            if a.saved_session:
                validate_cookies(result['cookies'],saved['vid'])
                for k,v in result['cookies'].items():web.set_cookie(k,v)
                phase='final_snapshot'
                if snapshot(api,web,grant)!=baseline:raise ValueError('translation_owner/cloud_changed')
                for index,uid in enumerate(payload['chapter_uids'] if a.range or a.full else [source['chapter_uid']]):
                    if a.full:observed,_=member_source(web,sample,int(uid),api.member['paying'])
                    else:web.inspect_content(sample,int(uid));observed=web.content_sample
                    expected=payload['source_hashes'][index] if a.range or a.full else payload['source_sha256']
                    if not observed or hashlib.sha256(observed['source'].encode()).hexdigest()!=expected:raise ValueError('translation_owner/source_changed')
                web.verify_account();save_refreshed_web_session(SessionStore(),saved,web)
                if (capture.read(),generation.read())!=retained or NativeSessionStore().load(saved['vid'])!=grant:raise ValueError('translation_owner/scope_changed')
                r.update(cloud_position_presence_and_shelf_unchanged=True,reported_counter_values_and_presence_unchanged=True,
                    cloud_position_present={k:baseline[k]['position_present'] for k in ('native','web')},
                    cloud_counter_fields_reported={k:len(baseline[k]['counters']) for k in ('native','web')},
                    source_exact_before_after=True,capture_and_generation_scopes_unchanged=True)
                if a.full:r['chapters_verified']=len(payload['chapter_uids'])
            r['result']='PASS_TRANSLATION_OWNER_NATIVE_UI'
    except Exception as error:
        r.update(result='UNVERIFIED',phase=phase)
        if str(error) in ('initial_position/counts','progress_not_found','progress_ambiguous','progress_invalid',
                'progress_book_mismatch','progress_rejected','translation_owner/cloud_changed','translation_owner/source_changed',
                'translation_owner/scope_changed','translation_owner/member_scope','translation_owner/no_range_content','translation_owner/no_existing_content','translation_owner/unknown_absence',
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
