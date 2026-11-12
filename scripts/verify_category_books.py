#!/usr/bin/env python3
"""Anonymous public ranking/main/child book lists; offline unless --online.

Only the known category hierarchy and at most two batches of three lists.
No Keychain, account, cookie, login, shelf, progress or write endpoint exists.
Public source responses and labels remain in captured memory pipes.
"""
import argparse
from datetime import datetime, timezone
import json
import math
import re
import subprocess
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from verify_category_catalog import project as catalog

BASE='https://weread.qq.com'
CATALOG=BASE+'/web/categories?rank=1&synckey=0'


def page(data, cursor=0):
    if (not isinstance(data,dict) or not isinstance(data.get('books'),list) or len(data['books'])>100
            or any(data.get(k,0) not in (None,0,'0') for k in ('errcode','errCode'))
            or 'succ' in data and data['succ'] not in (True,1,'1')):
        raise ValueError('category_books_shape')
    books=[];seen=set();last=cursor
    def text(value,limit):
        if value is None:return ''
        if type(value) not in (str,int,float):raise ValueError('category_book_text')
        result=str(value)
        if len(result.encode())>limit or re.search(r'[\x00-\x1f\x7f]',result):raise ValueError('category_book_text')
        return result
    for row in data['books']:
        if not isinstance(row,dict):raise ValueError('category_book_row')
        book=row
        for _index in range(4):
            nested=book.get('bookInfo',book.get('book'))
            if not isinstance(nested,dict):break
            book=nested
        identity=text(book.get('bookId',book.get('book_id',row.get('bookId'))),256)
        if not identity:continue
        idx=row.get('searchIdx',row.get('idx',book.get('searchIdx',book.get('idx'))))
        if idx is not None and (type(idx) not in (int,float) or not math.isfinite(idx) or idx!=int(idx) or not 0<=idx<=2**31-1):
            raise ValueError('category_book_cursor')
        last=max(last,idx if idx is not None else cursor)
        if identity not in seen:
            seen.add(identity)
            value=dict(bookId=identity,title=text(book.get('title'),4096),author=text(book.get('author'),4096),
                       cover=text(book.get('cover'),8192),category=text(book.get('category'),4096))
            if idx is not None:value['searchIdx']=idx
            books.append(value)
    more=data.get('hasMore',len(data['books'])>=20)
    return dict(books=books,next_cursor=last,has_more=more in (True,1,'1') and last>cursor)


def targets(tree):
    rank=tree['ranks'][0]
    parent=next(row for row in tree['categories'] if row['children'])
    child=parent['children'][0]
    if len({rank['id'],parent['id'],child['id']})!=3:raise ValueError('category_targets_not_distinct')
    return [dict(role=role,entry=entry) for role,entry in [('rank',rank),('main',parent),('child',child)]]


def url(entry,cursor):
    identity=entry['id']
    if (not isinstance(identity,str) or not re.fullmatch('[A-Za-z0-9_-]{1,128}',identity)
            or type(entry['rank']) is not bool or type(cursor) is not int or not 0<=cursor<=2**31-1):
        raise ValueError('category_request_scope')
    return BASE+'/web/bookListInCategory/'+identity+'?rank='+str(int(entry['rank']))+'&maxIndex='+str(cursor)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,*_args,**_kwargs):return None


class Probe:
    def __init__(self,opener=None,pause=time.sleep,clock=time.monotonic):
        self.opener=opener if opener is not None else build_opener(NoRedirect())
        self.pause,self.clock=pause,clock
        self.stages=[];self.last=None;self.allowed={CATALOG};self.calls=0

    def fetch(self,role,address):
        if role not in ('catalog','rank','main','child') or address not in self.allowed or self.calls>=7:
            raise ValueError('category_request_scope')
        parsed=urlsplit(address)
        if parsed.scheme!='https' or parsed.netloc!='weread.qq.com' or parsed.fragment:
            raise ValueError('category_request_scope')
        if self.last is not None:self.pause(max(0,1-(self.clock()-self.last)))
        self.last=self.clock();self.calls+=1
        record=dict(role=role);self.stages.append(record)
        request=Request(address,headers={'User-Agent':'Mozilla/5.0','Accept':'application/json',
                                        'Referer':BASE+'/web/category/all'},method='GET')
        try:
            with self.opener.open(request,timeout=15) as response:
                record['status']=response.status
                if response.status!=200 or response.url!=address:raise ValueError('category_http')
                raw=response.read(4*1024*1024+1)
                if len(raw)>4*1024*1024:raise ValueError('category_response_limit')
                return json.loads(raw)
        except HTTPError as error:
            record['status']=error.code;raise ValueError('category_http') from None

    def prepare(self):
        source=self.fetch('catalog',CATALOG);tree=catalog(source)
        selected=targets(tree);samples=[]
        for target in selected:
            cursor=0;first=None
            for _batch_index in range(2):
                address=url(target['entry'],cursor);self.allowed.add(address)
                raw=self.fetch(target['role'],address);expected=page(raw,cursor)
                if first is not None and {b['bookId'] for b in first['books']} & {b['bookId'] for b in expected['books']}:
                    raise ValueError('category_batch_overlap')
                samples.append(dict(role=target['role'],entry=target['entry'],cursor=cursor,expected=expected))
                if not expected['has_more']:break
                if type(expected['next_cursor']) is not int:raise ValueError('category_cursor_not_integer')
                first=expected;cursor=expected['next_cursor']
        return dict(catalog=tree,samples=samples)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--online',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.lua_command and not args.online:parser.error('--lua-command requires --online')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),authenticated=False,
                keychain_accesses=0,account_data_posts=0,authentication_posts=0,screenshots=0)
    probe=None
    try:
        if args.online:
            probe=Probe();payload=probe.prepare()
            report.update(result='PUBLIC_CATEGORY_BOOKS_PROTOCOL_VERIFIED',python_gets=probe.calls,
                          list_roles=['rank','main','child'],batch_sizes=[len(row['expected']['books']) for row in payload['samples']])
            if args.lua_command:
                from public_category_ui_contract import compare_runner,decode_runner
                raw=json.dumps(payload,ensure_ascii=False).encode()
                if len(raw)>2*1024*1024:raise ValueError('category_input_limit')
                child=subprocess.run(args.lua_command,input=raw,capture_output=True,timeout=360)
                report['ui']=decode_runner(child.stdout,len(payload['samples'])+1)
                report['ui']=compare_runner(child.stdout,payload)
                if child.returncode:raise ValueError('category_ui_failed')
                report.update(result='PUBLIC_CATEGORY_BOOKS_UI_AND_OFFLINE_VERIFIED',same_response_python_model=True)
    except Exception:report.update(result='UNVERIFIED',reason='public_category_books_unverified')
    finally:
        if probe:report['stages']=probe.stages
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','PUBLIC_CATEGORY_BOOKS_PROTOCOL_VERIFIED','PUBLIC_CATEGORY_BOOKS_UI_AND_OFFLINE_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
