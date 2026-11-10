#!/usr/bin/env python3
"""Read two selected source chapters twice; never write account data."""
import argparse
from datetime import datetime,timezone
import json
import re
import subprocess
from secure_weread_session import SessionStore
from verify_web_source_progress import WebSourceProbe,BASE,position
from verify_translation_preflight import save_refreshed_web_session
from fetch_weread_epub import normalize_chapter_infos
from source_currentness import inspect,FIELDS


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if (args.lua_command or args.native_http) and not args.saved_session or args.native_http and not args.lua_command:
        parser.error('comparisons require --saved-session and --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                authentication_posts_attempted=0,private_data_on_regular_disk=False,upload_enabled=False)
    probe=saved=samples=None
    try:
        if args.saved_session:
            store,probe=SessionStore(),WebSourceProbe();saved=store.load();probe.vid=saved['vid']
            for key,value in saved['cookies'].items():probe.set_cookie(key,value)
            probe.verify_account();book=probe.select_shelf_book()
            initial=position(probe.request('progress_before',BASE+'/web/book/getProgress?bookId='+book),book)
            probe.chapter=initial['chapter']
            catalog=probe.request('catalog_before',BASE+'/web/book/chapterInfos',dict(bookIds=[book]))
            _record,rows=normalize_chapter_infos(catalog,book)
            selected=[str(row['chapterUid']) for row in rows if type(row.get('wordCount')) is int and row['wordCount']>0 and row.get('title')!='封面']
            at=selected.index(initial['chapter'])
            neighbour=selected[at+1] if at+1<len(selected) else selected[at-1] if at else None
            if not neighbour:raise ValueError('source_neighbour_missing')
            samples=[]
            for uid in (initial['chapter'],neighbour):
                reference,_private=inspect(probe,book,uid)
                expected={key:reference[key] for key in FIELDS}
                observed,sample=inspect(probe,book,uid,expected)
                samples.append(sample)
                if observed!=reference:raise ValueError('source_observation_changed')
            after=position(probe.request('progress_after',BASE+'/web/book/getProgress?bookId='+book),book)
            report.update(result='REAL_SOURCE_CURRENTNESS_PROTOTYPE_VERIFIED',chapters=2,reads_per_check=8,
                          other_than_cloud_chapter_verified=True,cloud_position_unchanged=after==initial,
                          catalog_observations_stable=True,version_semantics_assumed=False)
            if after!=initial:raise ValueError('source_position_changed')
            if args.lua_command:
                data=dict(samples=samples)
                if args.native_http:data.update(native_http=True,vid=probe.vid,cookies={c.name:c.value for c in probe.cookies})
                child=subprocess.run(args.lua_command,input=json.dumps(data,ensure_ascii=False).encode(),capture_output=True,timeout=180)
                frame=b'\nSOURCE_CURRENTNESS_RESULT='
                if len(child.stdout)>2*1024*1024 or child.stdout.count(frame)!=1:raise ValueError('source_comparison_frame')
                returned=json.loads(child.stdout.split(frame)[1])
                if isinstance(returned,dict) and re.fullmatch('source_currentness/[a-z_]+',str(returned.get('error',''))):
                    report['native_diagnostic']=returned['error']
                from source_currentness import project
                expected=[project(**sample) for sample in samples]
                if child.returncode or returned!=expected:raise ValueError('source_comparison')
                report.update(result='REAL_SOURCE_CURRENTNESS_LUA_VERIFIED',lua_native_http=args.native_http)
    except Exception:
        report.update(result='UNVERIFIED',reason='source_currentness_unverified')
    finally:
        if probe:
            try:
                probe.verify_account();report['rotation_saved']=save_refreshed_web_session(store,saved,probe)
            except Exception:report.update(result='UNVERIFIED',reason='source_currentness_unverified')
            report['stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in probe.report['stages']]
            probe.close()
        if saved:saved.clear()
        if samples:samples.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
