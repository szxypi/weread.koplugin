#!/usr/bin/env python3
"""Bounded public category hierarchy; offline unless --online is explicit.

No credentials, account, cookies, shelf, progress or translation APIs are used.
The existing public bookstore GET contract is documented by verify_bookstore.py.
Responses stay in memory; reports contain counts, status and booleans only.
"""
import argparse
from datetime import datetime,timezone
import json
import re
import subprocess
import time
from urllib.request import Request,urlopen

MAX_NODES=5000
MAX_PAYLOAD=1024*1024


def project(data,now=None):
    if not isinstance(data,dict) or not isinstance(data.get('data'),list): raise ValueError('category_shape')
    for key in ('errcode','errCode'):
        if key in data and data[key] not in (0,'0',None): raise ValueError('category_rejected')
    if 'succ' in data and data['succ'] not in (True,1,'1'): raise ValueError('category_rejected')
    count=0
    def bound(rows,depth=0):
        nonlocal count
        if not isinstance(rows,list) or depth>16: raise ValueError('category_shape')
        for row in rows:
            count+=1
            if count>MAX_NODES: raise ValueError('category_limit')
            if not isinstance(row,dict): continue
            title=row.get('title')
            if title is not None and (not isinstance(title,str) or len(title.encode())>4096
                    or re.search(r'[\x00-\x1f\x7f]',title)): raise ValueError('category_title')
            for key in ('categories','sublist'):
                if key in row: bound(row[key],depth+1)
    bound(data['data'])
    def parse(row,depth=0):
        if not isinstance(row,dict) or depth>8: return None
        identity=str(row.get('CategoryId',row.get('categoryId','')))
        title=str(row.get('title',''))
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',identity) or not title or row.get('type') not in (None,0,'0'): return None
        result=dict(id=identity,title=title,rank=not identity.isdigit(),children=[])
        for child in row.get('sublist',[]):
            value=parse(child,depth+1)
            if value: result['children'].append(value)
        return result
    result=dict(schema=1,loaded_at=int(time.time()) if now is None else now,ranks=[],categories=[])
    seen=set()
    def visit(rows,depth=0):
        if depth>8: return
        for row in rows:
            if not isinstance(row,dict): continue
            if isinstance(row.get('categories'),list): visit(row['categories'],depth+1)
            else:
                value=parse(row)
                if value and value['id'] not in seen:
                    seen.add(value['id']);result['ranks' if value['rank'] else 'categories'].append(value)
    visit(data['data'])
    if not result['ranks'] and not result['categories']: raise ValueError('category_empty')
    if len(json.dumps(result,ensure_ascii=False).encode())>MAX_PAYLOAD: raise ValueError('category_limit')
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--online',action='store_true')
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args()
    if (args.lua_command and not args.online) or (args.native_http and not args.lua_command): parser.error('Lua comparison requires --online; --native-http also requires --lua-command')
    report=dict(checked_at=datetime.now(timezone.utc).isoformat(),result='OFFLINE_ONLY',authenticated=False,account_data_writes=0)
    if not args.online:
        assert project(dict(data=[dict(CategoryId='100',title='Synthetic')]))['categories'][0]['id']=='100'
        print(json.dumps(report,indent=2));return 0
    try:
        request=Request('https://weread.qq.com/web/categories?rank=1&synckey=0',headers={
            'User-Agent':'Mozilla/5.0','Accept':'application/json','Referer':'https://weread.qq.com/web/category/all'})
        with urlopen(request,timeout=15) as response:
            if response.status!=200 or response.url!=request.full_url: raise ValueError('category_http')
            raw=response.read(4*1024*1024+1)
            if len(raw)>4*1024*1024: raise ValueError('category_limit')
        source=json.loads(raw);expected=project(source)
        report.update(http_status=200,ranks=len(expected['ranks']),categories=len(expected['categories']))
        def count(rows): return sum(1+count(row['children']) for row in rows)
        report['total_entries']=count(expected['ranks'])+count(expected['categories'])
        if args.lua_command:
            payload=json.dumps(dict(source=source,now=expected['loaded_at'],native_http=args.native_http),ensure_ascii=False).encode()
            if len(payload)>4*1024*1024: raise ValueError('category_input_limit')
            child=subprocess.run(args.lua_command,input=payload,capture_output=True,timeout=45)
            frame=b'\nWEREAD_CATEGORY_RESULT='
            if child.returncode or len(child.stdout)>2*MAX_PAYLOAD or child.stdout.count(frame)!=1: raise ValueError('category_lua_failed')
            actual=json.loads(child.stdout.split(frame)[1])
            # Lua's JSON codecs may encode an empty array as an empty object.
            def canonical(value):
                for key in ('ranks','categories','children'):
                    if key in value:
                        if value[key]=={}: value[key]=[]
                        for row in value[key]: canonical(row)
                return value
            if canonical(actual['model'])!=expected: raise ValueError('category_lua_mismatch')
            report['lua_projection_matches']=True
            if args.native_http:
                native=canonical(actual['native']);native['loaded_at']=expected['loaded_at']
                if native!=expected or actual.get('requests')!=1: raise ValueError('category_native_mismatch')
                report.update(native_https_matches=True,native_read_requests=1)
        report['result']='PUBLIC_CATEGORY_VERIFIED'
    except Exception:
        report.update(result='UNVERIFIED',reason='public_category_verification_failed')
    print(json.dumps(report,indent=2))
    return 0 if report['result']=='PUBLIC_CATEGORY_VERIFIED' else 1


if __name__=='__main__': raise SystemExit(main())
