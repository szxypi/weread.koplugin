#!/usr/bin/env python3
"""Read-only CB_ shelf progress prototype; offline unless --saved-session.

Compare native/Web shelf identities before reading at most eight CB_ books.
Only fixed Web progress GETs are permitted; redirects, repeated addresses,
account writes and authorization renewal are absent. Private responses and
positions remain in memory/captured pipes. No inference about book ownership,
upload support, metadata, source coordinates or write semantics is made.
"""
import argparse
from datetime import datetime,timezone
import json
import re
import subprocess
from urllib.error import HTTPError,URLError
from urllib.parse import urlencode
from urllib.request import Request,build_opener

from fetch_weread_epub import USER_AGENT,weread_e
from secure_native_session import NativeSessionStore
from secure_weread_session import COOKIE_NAMES,SessionStore
from verify_eink_login import BASE as NATIVE_BASE,NativeProbe
from verify_shelf_progress import parse
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,NoRedirect,WebSourceProbe


class CbError(ValueError):pass


def cb_id(value):
    return value if isinstance(value,str) and re.fullmatch(r'CB_[A-Za-z0-9]{1,64}',value) else None


def cb_ids(value):
    books=value.get('books') if isinstance(value,dict) else None
    if not isinstance(books,list) or len(books)>5000:raise CbError('cb_shelf_invalid')
    seen=set();selected=[]
    for row in books:
        identity=row.get('bookId') if isinstance(row,dict) else None
        if not isinstance(identity,(str,int)) or isinstance(identity,bool):raise CbError('cb_shelf_invalid')
        identity=str(identity)
        if not identity or identity in seen:raise CbError('cb_shelf_invalid')
        seen.add(identity)
        if identity.startswith('CB_'):
            if not cb_id(identity):raise CbError('cb_identity_invalid')
            selected.append(identity)
    if not 1<=len(selected)<=8:raise CbError('cb_sample_limit')
    return sorted(selected)


class CbProgressProbe:
    def __init__(self,cookies,identities,opener=None):
        if (not isinstance(identities,list) or not 1<=len(identities)<=8
                or any(not cb_id(value) for value in identities) or len(set(identities))!=len(identities)):
            raise CbError('cb_identity_invalid')
        if (not isinstance(cookies,dict) or not cookies or any(key not in COOKIE_NAMES or not isinstance(value,str)
                or not value or len(value)>4096 or any(ord(char)<33 or ord(char)>126 or char in ';"\\' for char in value)
                for key,value in cookies.items())):raise CbError('cb_cookie_invalid')
        self.cookie='; '.join(key+'='+cookies[key] for key in sorted(cookies))
        self.allowed=set(identities);self.used=set();self.stages=[]
        self.opener=opener or build_opener(NoRedirect())

    def fetch(self,identity):
        if not cb_id(identity) or identity not in self.allowed or identity in self.used:raise CbError('cb_read_outside_scope')
        self.used.add(identity)
        record=dict(stage='cb_progress');self.stages.append(record)
        request=Request(BASE+'/web/book/getProgress?'+urlencode(dict(bookId=identity)),method='GET',
                        headers={'User-Agent':USER_AGENT,'Accept':'application/json','Cookie':self.cookie,
                                 'Origin':BASE,'Referer':BASE+'/web/reader/'+weread_e(identity)})
        try:
            with self.opener.open(request,timeout=10) as response:
                record['status']=response.status
                if response.status!=200:raise CbError('cb_http_rejected')
                raw=response.read(65537)
            if len(raw)>65536:raise CbError('cb_response_limit')
            value=json.loads(raw)
            if not isinstance(value,dict):raise CbError('cb_response_invalid')
            return value
        except HTTPError as exc:
            record['status']=exc.code;exc.close();raise CbError('cb_http_rejected') from None
        except (URLError,TimeoutError,OSError):raise CbError('cb_connection_unverified') from None
        except (UnicodeError,ValueError) as exc:
            if isinstance(exc,CbError):raise
            raise CbError('cb_response_invalid') from None

    def close(self):
        self.cookie='';self.allowed.clear();self.used.clear()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session or args.native_http and not args.lua_command:
        parser.error('Lua comparison needs --saved-session; --native-http also needs --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),
                account_data_posts=0,authentication_posts=0,credentials_written_to_files=False,
                raw_positions_or_identities_exported=False,cb_progress_gets=0)
    saved=credentials=web=probe=None;samples=[]
    try:
        if args.saved_session:
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid'])
            native=NativeProbe();ids=cb_ids(native.request('cb_native_shelf',NATIVE_BASE+'/shelf/sync',credentials=credentials))
            web=WebSourceProbe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            if cb_ids(web.request('shelf',BASE+'/web/shelf/sync'))!=ids:raise CbError('cb_shelf_identity_changed')
            report['web_cookie_rotation_saved']=save_refreshed_web_session(store,saved,web)
            cookies={cookie.name:cookie.value for cookie in web.cookies if cookie.name in COOKIE_NAMES
                     and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
            probe=CbProgressProbe(cookies,ids)
            expected=[]
            for identity in ids:
                raw=probe.fetch(identity);value=parse(raw,identity)
                samples.append(dict(book_id=identity,raw=raw))
                if value is not None:expected.append(dict(book_id=identity,percent=value))
            report.update(same_owner_verified=True,shelf_cb_identities_match=True,cb_books=len(ids),
                          known_progress=len(expected),unavailable_progress=len(ids)-len(expected))
            if args.lua_command:
                payload=dict(samples=samples)
                if args.native_http:payload['session']=dict(vid=saved['vid'],cookies=cookies)
                encoded=json.dumps(payload).encode()
                if len(encoded)>1024*1024:raise CbError('cb_comparison_limit')
                child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=150)
                frame=b'\nWEREAD_DISPLAY_RESULT='
                if child.returncode or len(child.stdout)>1024*1024 or child.stdout.count(frame)!=1:
                    raise CbError('cb_lua_unverified')
                actual=json.loads(child.stdout.split(frame)[1])
                if actual.get('model')!=expected:raise CbError('cb_lua_unverified')
                report['lua_model_matches']=True
                if args.native_http:
                    if actual.get('native')!=expected or actual.get('requests')!=len(ids):raise CbError('cb_lua_unverified')
                    report.update(lua_https_matches=True,lua_progress_gets=len(ids))
            report.update(result='CB_DISPLAY_PROGRESS_READ_VERIFIED',python_preflight_gets=3)
    except Exception:report.update(result='UNVERIFIED',reason='cb_progress_verification_failed')
    finally:
        if probe:report['cb_progress_gets']=len(probe.stages);report['stages']=probe.stages;probe.close()
        if web:web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
        samples.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','CB_DISPLAY_PROGRESS_READ_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
