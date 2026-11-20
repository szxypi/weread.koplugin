#!/usr/bin/env python3
"""Independent real read-only Python/native-Lua existing-translation comparison.

No mode/generation/renewal/purchase channel. Private inputs use memory pipes.
"""
import argparse,hashlib,json,re,resource,subprocess
from datetime import datetime,timezone
from secure_weread_session import SessionStore,COOKIE_NAMES
from secure_native_session import NativeSessionStore
from secure_translation_generation import TranslationGenerationStore
from native_time_capture import NativeCaptureStore
from verify_translation_preflight import TranslationProbe,TranslationWebProbe,save_refreshed_web_session
from verify_owner_reading import validate_cookies

FRAME=b'\nWEREAD_TRANSLATION_FETCH_HTTP='


def compare(result,samples):
    if not isinstance(result,dict) or not isinstance(result.get('samples'),list) or len(result['samples'])!=len(samples):raise ValueError('translation_fetch/shape')
    for actual,wanted in zip(result['samples'],samples):
        if (not isinstance(wanted,dict) or not isinstance(wanted.get('sha256'),str) or not re.fullmatch('[a-f0-9]{64}',wanted['sha256'])
                or type(wanted.get('blocks')) is not int or not 1<=wanted['blocks']<=20000
                or not isinstance(actual,dict) or actual.get('sha256')!=wanted['sha256']
                or type(actual.get('blocks')) is not int or actual['blocks']!=wanted['blocks']
                or type(actual.get('pairs')) is not int or not 0<=actual['pairs']<=actual['blocks']):raise ValueError('translation_fetch/mismatch')


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=p.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):p.error('saved access and private Lua command must be paired')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
        authentication_posts=0,translation_mode_requests=0,generation_requests=0,trial_activations=0,purchases=0,private_data_on_regular_disk=False)
    saved=grant=web=api=None;phase='init'
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            capture_store=NativeCaptureStore();capture_before=capture_store.read()
            generation_store=TranslationGenerationStore();generation_before=generation_store.read()
            saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
            phase='native_discovery';api=TranslationProbe();api.inspect(grant,2,True)
            web=TranslationWebProbe();web.vid=saved['vid']
            for k,v in saved['cookies'].items():web.set_cookie(k,v)
            phase='web_account';web.verify_account();samples=[]
            phase='python_content'
            for sample in api.samples:
                observed=web.inspect_content(sample);content=web.content_sample
                if not observed.get('content_decoded') or not content or observed['nonempty_translation_blocks']<1:raise ValueError('translation_fetch/no_existing_content')
                samples.append(dict(book_id=sample['book_id'],chapter_uid=str(content['chapter_uid']),
                    sha256=hashlib.sha256(content['source'].encode()).hexdigest(),blocks=observed['nonempty_translation_blocks']))
            encoded=json.dumps(dict(cookies={c.name:c.value for c in web.cookies if c.name in COOKIE_NAMES
                and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'},samples=samples),separators=(',',':')).encode()
            phase='lua';child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            if len(child.stdout)<=1024*1024 and child.stdout.count(FRAME)==1:
                value=json.loads(child.stdout.split(FRAME)[1])
                if isinstance(value,dict) and value.get('error'):
                    if value.get('stage') in ('input','client','reader','catalog','chapter','analysis'):report['lua_stage']=value['stage']
                    if type(value.get('line')) is int and 0<value['line']<=10000:report['lua_line']=value['line']
            if child.returncode or len(child.stdout)>1024*1024 or child.stdout.count(FRAME)!=1:raise ValueError('translation_fetch/native_unavailable')
            phase='compare';actual=json.loads(child.stdout.split(FRAME)[1]);compare(actual,samples)
            phase='cookies';actual['cookies']={k:v for k,v in actual['cookies'].items() if k in COOKIE_NAMES}
            validate_cookies(actual['cookies'],saved['vid'])
            for k,v in actual['cookies'].items():web.set_cookie(k,v)
            phase='final_account';web.verify_account();save_refreshed_web_session(SessionStore(),saved,web)
            phase='scopes'
            if capture_store.read()!=capture_before or generation_store.read()!=generation_before or NativeSessionStore().load(saved['vid'])!=grant:
                raise ValueError('translation_fetch/retained_scope_changed')
            report.update(result='PASS_REAL_PYTHON_LUA_EXISTING_TRANSLATION',samples=len(samples),
                translated_blocks=[s['blocks'] for s in samples],source_bytes_exact=True,independent_native_https=True,
                capture_and_generation_scopes_unchanged=True,native_grant_unchanged=True)
    except Exception:report.update(result='UNVERIFIED',reason='translation_fetch/readonly_adapter_unavailable',stage=phase)
    finally:
        if api:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in api.report['stages']]
        if web:
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.close()
        for value in (saved,grant):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
