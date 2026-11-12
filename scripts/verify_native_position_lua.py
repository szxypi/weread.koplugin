#!/usr/bin/env python3
"""Read-only source-bound comparison of Python and native Lua position DTOs."""
import argparse
from datetime import datetime,timezone
import json
import math
import resource
import secrets
import subprocess
import time
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from verify_native_txt_position import Native,Source,inspect
from verify_translation_preflight import save_refreshed_web_session
from native_txt_summary import prepare as slide
from native_txt_read_model import body
from readtime_upload_model import local_zone
from verify_reader_progress import find_node,project


def equivalent(expected,actual):
    if type(expected) in (int,float):return type(actual) in (int,float) and math.isfinite(actual) and actual==expected
    if type(expected) is not type(actual):return False
    if isinstance(expected,dict):return set(expected)==set(actual) and all(equivalent(v,actual[k]) for k,v in expected.items())
    if isinstance(expected,list):return len(expected)==len(actual) and all(equivalent(a,b) for a,b in zip(expected,actual))
    return expected==actual


def compare(credentials,point,version,guest,now,random,zone,chapter_progress,command,runner=subprocess.run,native_response=None):
    payload=dict(credentials=credentials,point=point,version=version,guest=guest,now=now,random=random,time_zone=zone)
    if chapter_progress is not None:payload['chapter_progress']=chapter_progress
    expected={'result':'PASS','body':body(credentials,point,version,guest,now,random,zone,chapter_progress)}
    if native_response is not None:
        payload['native_response']=native_response;position=project(native_response,point['book_id'],'native');node=find_node(native_response,point['book_id'])
        snapshot_point={key:position[key] for key in ('book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')}
        snapshot_point['chapter_uid']=str(snapshot_point['chapter_uid'])
        expected['snapshot']=dict(position=snapshot_point,counts={key:node[key] for key in ('readingTime','recordReadingTime','ttsTime')})
    raw=json.dumps(payload,ensure_ascii=False).encode()
    if len(raw)>65536:raise ValueError('native_position_lua/input_limit')
    child=runner(command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=60)
    if child.returncode or not isinstance(child.stdout,bytes) or len(child.stdout)>65536:raise ValueError('native_position_lua/child')
    try:value=json.loads(child.stdout)
    except Exception:raise ValueError('native_position_lua/response') from None
    if not equivalent(expected,value):raise ValueError('native_position_lua/mismatch')


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if a.saved_session!=bool(a.lua_command):p.error('saved session and a nonempty private Lua command required together')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,
        private_data_on_regular_disk=False,production_upload_enabled=False)
    web=saved=credentials=native=None
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid'])
            web=Source();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            if not web.find_sample(limit=16):raise ValueError('native_position_lua/no_sample')
            plan=web.inspect_plan();native=Native(credentials,web.book_id);observation=inspect(web,native,credentials,plan,report)
            candidate=slide(web.sample['plain'],plan);cp=find_node(observation['native_progress'],web.book_id).get('chapterProgress')
            for point in (candidate['baseline'],candidate['target']):
                compare(credentials,point,observation['version'],observation['guest'],int(time.time()),secrets.randbelow(1000),local_zone(),cp,a.lua_command,native_response=observation['native_progress'])
            report.update(result='NATIVE_POSITION_LUA_REAL_DTO_MATCH_VERIFIED',payloads_compared=2,full_summary_scalars=len(candidate['baseline']['summary']),
                empty_array_preserved=True,all_signed_fields_match=True,actual_native_position_and_counters_projected=True,native_write_flow_verified=False)
    except (Exception,KeyboardInterrupt):report['result']='UNVERIFIED'
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,saved,web)
                except Exception:report['result']='UNVERIFIED'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.sample=None;web.close()
        if native:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in native.report['stages']]
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
