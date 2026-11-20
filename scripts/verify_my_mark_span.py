#!/usr/bin/env python3
"""Read-only real-highlight boundary/anchor comparison, no cloud modifications."""
import argparse
import contextlib
import io
import json
import subprocess
from my_mark_span import project,verify_anchor
import verify_my_mark_target as target


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,private_files=False);records={};old=target.project
    try:
        if args.saved_session:
            def observe(raw,book,chapter,row):
                result=old(raw,book,chapter,row);expected=project(raw,book,chapter,row)
                batch=records.setdefault(chapter,dict(raw=raw,book_id=book,chapter_uid=chapter,rows=[],expected=[]))
                if batch['raw']!=raw:raise ValueError('my_mark_span/changed')
                batch['rows'].append(row);batch['expected'].append(expected);return result
            target.project=observe
            with contextlib.redirect_stdout(io.StringIO()) as output:code=target.main(['--saved-session'])
            report['preflight']=json.loads(output.getvalue())
            if code or not records:raise ValueError('my_mark_span/preflight')
            count=0
            if args.lua_command:
                for batch in records.values():
                    data={k:v for k,v in batch.items() if k!='expected'}
                    child=subprocess.run(args.lua_command,input=json.dumps(data,ensure_ascii=False).encode(),capture_output=True,timeout=120)
                    frame=b'\nWEREAD_MY_MARK_SPAN_RESULT='
                    if child.returncode or child.stdout.count(frame)!=1 or len(child.stdout)>4*1024*1024:raise ValueError('my_mark_span/lua')
                    rows=json.loads(child.stdout.split(frame)[1])
                    if len(rows)!=len(batch['expected']):raise ValueError('my_mark_span/rows')
                    for row,expected in zip(rows,batch['expected']):
                        first,last=row.pop('first_anchor'),row.pop('last_anchor')
                        if row!=expected:raise ValueError('my_mark_span/different')
                        verify_anchor(batch['raw'],expected['first'],first);verify_anchor(batch['raw'],expected['last'],last);count+=1
            report.update(result='PASS',marks=sum(len(r['rows']) for r in records.values()),chapters=len(records),both_anchors_verified=count,python_lua_match=bool(args.lua_command))
        elif args.lua_command:raise ValueError('my_mark_span/offline')
    except Exception:report.update(result='UNVERIFIED')
    finally:target.project=old;records.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
