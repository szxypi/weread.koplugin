#!/usr/bin/env python3
"""Live read-only chapter preflight in KOReader, with a memory-only EPUB fixture."""
import argparse,json,resource,subprocess
from datetime import datetime,timezone
from secure_weread_session import SessionStore,COOKIE_NAMES
from secure_native_session import NativeSessionStore
from verify_translation_preflight import TranslationProbe,TranslationWebProbe,save_refreshed_web_session
from verify_owner_reading import validate_cookies

FRAME=b'\nTRANSLATION_SOURCE='


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.saved_session!=bool(args.lua_command):parser.error('saved session and private Lua command required together')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
        authentication_posts=0,translation_mode_requests=0,generation_requests=0,purchases=0,trial_activations=0,
        private_data_on_regular_disk=False,archive_fixture='memory_only')
    saved=grant=api=web=None;phase='init'
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
            api=TranslationProbe();api.inspect(grant,1,True);sample=api.samples[0]
            web=TranslationWebProbe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();phase='source'
            summary=web.inspect_content(sample);content=web.content_sample
            if not content or not summary.get('nonempty_translation_blocks'):raise ValueError('no_translation')
            cookies={c.name:c.value for c in web.cookies if c.name in COOKIE_NAMES
                and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'}
            validate_cookies(cookies,saved['vid'])
            payload=dict(credentials=grant,cookies=cookies,book_id=sample['book_id'],uid=str(content['chapter_uid']),
                version=sample['expected']['version'],source=content['source'])
            encoded=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
            if len(encoded)>3*1024*1024:raise ValueError('input_limit')
            phase='lua';child=subprocess.run(args.lua_command,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=180)
            if child.returncode or len(child.stdout)>65536 or child.stdout.count(FRAME)!=1:raise ValueError('native_unavailable')
            result=json.loads(child.stdout.split(FRAME)[1])
            if not isinstance(result,dict) or result.get('kind')!='available':
                if isinstance(result,dict) and result.get('reason') in ('session_changed','local_source','catalog','catalog_changed','version',
                    'source_changed','missing_original','structural','unavailable'):
                    report['native_reason']=result['reason']
                if isinstance(result,dict) and type(result.get('native_reads')) is int and 0<=result['native_reads']<=12:report['native_reads']=result['native_reads']
                if isinstance(result,dict) and type(result.get('web_reads')) is int and 0<=result['web_reads']<=32:report['web_reads']=result['web_reads']
                raise ValueError('native_mismatch')
            if result.get('native_reads')!=12 or type(result.get('web_reads')) is not int or not 1<=result['web_reads']<=32:
                raise ValueError('native_read_count')
            validate_cookies(result.get('cookies'),saved['vid'])
            for key,value in result['cookies'].items():web.set_cookie(key,value)
            phase='final_account';web.verify_account();save_refreshed_web_session(SessionStore(),saved,web)
            if NativeSessionStore().load(saved['vid'])!=grant:raise ValueError('grant_changed')
            report.update(result='NATIVE_SOURCE_EXISTING_TRANSLATION_VERIFIED',native_reads=result['native_reads'],
                web_reads=result['web_reads'],repeated_catalog_and_source=True,actual_epub_archive_verified=False)
    except (Exception,KeyboardInterrupt):report.update(result='UNVERIFIED',stage=phase)
    finally:
        if api:
            report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in api.report['stages']]
            api.samples=[]
        if web:
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.content_sample=None;web.close()
        for value in (saved,grant):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
