#!/usr/bin/env python3
"""Read-only selection-range comparison using the verified highlight preflight.

No account mutation, authentication POST, persistent private source or image.
The default is offline. Optional Lua inputs/results remain in captured pipes.
"""
import argparse
import contextlib
import io
import json
import subprocess
from selection_quote import Selection
import verify_my_mark_target as target


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session:parser.error('saved session required')
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,private_data_persisted=False)
    records={};indices={};old=target.project;old_inspect=target.inspect;failure=None;checked_indices=0
    try:
        if args.saved_session:
            def inspect(*a,**kw):
                observed,sample=old_inspect(*a,**kw)
                uid=observed['chapter_uid'];index=observed['chapter_idx']
                if uid in indices and indices[uid]!=index:raise ValueError('selection_quote/catalog_changed')
                indices[uid]=index;return observed,sample
            def compare(raw,book,chapter,row):
                nonlocal failure,checked_indices
                original=old(raw,book,chapter,row)
                if len(row['markText'].encode())>4096:return original
                try:
                    if row.get('chapterIdx') is not None:
                        if row['chapterIdx']!=indices[chapter]:raise ValueError('selection_quote/chapter_index')
                        checked_indices+=1
                    if chapter not in records:records[chapter]=dict(model=Selection(raw),selections=[],expected=[])
                    item=records[chapter]
                    if item['model'].raw!=raw:raise ValueError('selection_quote/source_changed')
                    selection,value=item['model'].from_mark(row)
                    item['selections'].append(selection);item['expected'].append(value)
                except (ValueError,KeyError,TypeError):failure='selection_quote/roundtrip';raise ValueError(failure) from None
                return original
            target.project=compare;target.inspect=inspect;output=io.StringIO()
            with contextlib.redirect_stdout(output):code=target.main(['--saved-session'])
            baseline=json.loads(output.getvalue());report['read_only_preflight']=baseline
            if code or failure:raise ValueError(failure or 'selection_quote/preflight')
            count=sum(len(v['expected']) for v in records.values())
            if not count or len(records)>8:raise ValueError('selection_quote/samples')
            if args.lua_command:
                for item in records.values():
                    payload=dict(raw=item['model'].raw,selections=item['selections'])
                    child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=90)
                    marker=b'\nWEREAD_SELECTION_QUOTE_RESULT='
                    if child.returncode or len(child.stdout)>512*1024 or child.stdout.count(marker)!=1:raise ValueError('selection_quote/lua')
                    actual=json.loads(child.stdout.split(marker)[1])
                    if actual!=item['expected']:raise ValueError('selection_quote/difference')
            report.update(result='SELECTION_QUOTE_VERIFIED',selections=count,chapters=len(records),python_roundtrip=True,
                          lua_matches=bool(args.lua_command),native_and_web_chapter_indices_compared=checked_indices,
                          optional_native_chapter_index_omitted=True,
                          scope='Saved cloud highlights within the 4096-byte quote limit',data_write_permission=False)
    except (Exception,KeyboardInterrupt):
        report.update(result='UNVERIFIED',reason=failure or 'selection_quote/comparison')
    finally:target.project=old;target.inspect=old_inspect;records.clear();indices.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
