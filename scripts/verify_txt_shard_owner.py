#!/usr/bin/env python3
"""Read one real TXT chapter and verify both shards in KOReader Lua, offline by default."""
import argparse
import json
import subprocess

from secure_weread_session import SessionStore
from verify_translation_preflight import save_refreshed_web_session
from verify_txt_reading import TxtProbe


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('pair --saved-session and --lua-command last')
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,private_data_saved=False)
    saved=web=None
    try:
        if args.saved_session:
            store=SessionStore();saved=store.load();web=TxtProbe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            if not web.find_sample(limit=8):raise ValueError('txt_shard/no_sample')
            sample=web.sample;t0,t1=sample['shards'];plain=sample['plain']
            if not isinstance(t1,str) or len(t1)<=32:raise ValueError('txt_shard/empty')
            from fetch_weread_epub import decode_content_shards
            try:missing_matches=decode_content_shards(t0,'','')==plain
            except Exception:missing_matches=False
            if missing_matches:raise ValueError('txt_shard/no_difference')
            encoded=json.dumps(dict(t0=t0,t1=t1,plain=plain),ensure_ascii=False).encode()
            if len(encoded)>8*1024*1024:raise ValueError('txt_shard/limit')
            child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=60)
            marker=b'\nWEREAD_TXT_SHARD_RESULT='
            if child.returncode or len(child.stdout)>65536 or child.stdout.count(marker)!=1:raise ValueError('txt_shard/lua')
            value=json.loads(child.stdout.split(marker)[1])
            flags=('complete_source_matches','second_shard_failure_rejected','partial_source_not_cached')
            if (not isinstance(value,dict) or set(value)!={'result',*flags} or value['result']!='PASS'
                    or any(value[key] is not True for key in flags)):
                raise ValueError('txt_shard/lua')
            web.verify_account();save_refreshed_web_session(store,saved,web)
            report.update(result='REAL_TXT_SHARDS_VERIFIED',second_shard_nonempty=True,
                          missing_second_changes_result=True,lua_complete_source_matches=True,
                          lua_failure_rejected_without_cache=True)
    except Exception:
        report.update(result='UNVERIFIED',reason='txt_shard/unverified')
    finally:
        if web:web.sample=None;web.close()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','REAL_TXT_SHARDS_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
