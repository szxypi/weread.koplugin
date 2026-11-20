#!/usr/bin/env python3
"""Offline by default; optional retained-session read-only candidate comparison."""
import argparse
import json
import subprocess
from secure_weread_session import SessionStore
from verify_owner_progress_preview import Preflight
from fetch_weread_epub import decode_content_shards,normalize_chapter_infos
from source_upload_candidate import project
from verify_translation_preflight import save_refreshed_web_session


class Probe(Preflight):
    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage=='catalog_after':self.chapters=normalize_chapter_infos(value,self.book_id)[1]
        return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session:parser.error('--lua-command requires --saved-session')
    report=dict(result='OFFLINE_ONLY',account_data_writes_attempted=0,authentication_posts_attempted=0,
                private_data_on_regular_disk=False,upload_enabled=False)
    web=saved=payload=raw=None
    try:
        if args.saved_session:
            web=Probe();store=SessionStore();saved=store.load();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            try:
                payload=web.prepare();raw=decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3')))
                cases=[]
                for key in ('baseline','target'):
                    point=payload['progress_preview'][key]
                    expected=project(raw,point,web.chapters,point['raw_percent'])
                    cases.append(dict(point=point,percent=point['raw_percent'],expected=expected))
                report.update(result='REAL_SOURCE_CANDIDATES_MODEL_VERIFIED',candidates=len(cases),summary_limit_scalars=20,
                              source_boundaries_verified=True,chapter_indices_verified=True,percent_derived_from_source_offset=False)
                if args.lua_command:
                    private=dict(raw=raw,chapters=web.chapters,cases=[{k:case[k] for k in ('point','percent')} for case in cases])
                    child=subprocess.run(args.lua_command,input=json.dumps(private,ensure_ascii=False).encode(),capture_output=True,timeout=60)
                    frame=b'\nSOURCE_UPLOAD_CANDIDATES='
                    if len(child.stdout)>2*1024*1024 or child.stdout.count(frame)!=1:raise ValueError('candidate_lua_frame')
                    returned=json.loads(child.stdout.split(frame)[1])
                    if child.returncode or returned!=[case['expected'] for case in cases]:raise ValueError('candidate_lua_mismatch')
                    report.update(result='REAL_SOURCE_CANDIDATES_LUA_VERIFIED',independent_lua_comparison=True)
            finally:
                web.verify_account();report['rotation_saved']=save_refreshed_web_session(store,saved,web)
    except Exception:
        report.update(result='UNVERIFIED',reason='candidate_unverified')
    finally:
        if web:
            report['stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.shards.clear();web.raw_progress=web.reader=web.plan=None;web.close()
        if saved:saved.clear()
        if payload:payload.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
