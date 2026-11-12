#!/usr/bin/env python3
"""Bounded Web-credential maintenance prototype; offline unless explicitly selected.

Uses the existing Keychain scope, one durable renewal intent and the verified
renewal protocol. No reading/shelf/annotation writes or credential files.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request,build_opener
from fetch_weread_epub import USER_AGENT
from secure_weread_session import SessionStore
from verify_mp_catalog import MPProbe
from verify_mp_link import NoRedirect
from verify_translation_preflight import save_refreshed_web_session


def anonymous_account(vid,opener=None):
    request=Request('https://weread.qq.com/api/userInfo?'+urlencode({'userVid':vid}),
                    headers={'User-Agent':USER_AGENT,'Accept':'application/json'},method='GET')
    try:
        with (opener or build_opener(NoRedirect())).open(request,timeout=20) as response:
            raw=response.read(65537);status=response.status
        value=json.loads(raw) if len(raw)<=65536 else None
        returned=value.get('vid',value.get('userVid')) if isinstance(value,dict) else None
        return {'status':status,'returns_requested_profile':str(returned)==vid,'cookie_sent':False,'redirects_followed':0}
    except HTTPError as exc:
        result={'status':exc.code,'returns_requested_profile':False,'cookie_sent':False,'redirects_followed':0};exc.close();return result
    except Exception:return {'status':None,'returns_requested_profile':False,'cookie_sent':False,'redirects_followed':0}


def native_renew(store,saved,probe,command,report):
    pending=store.begin_renewal(saved)
    headers=saved.get('web',{}).get('headers',{})
    private={'vid':saved['vid'],'cookies':saved['cookies'],'wr_ticket':headers.get('wr_ticket',''),'wr_wrpa':headers.get('wr_wrpa','')}
    encoded=json.dumps(private,separators=(',',':')).encode()
    if len(encoded)>131072:raise ValueError()
    # The intent precedes process creation. A lost pipe never causes a new POST.
    report.update(native_dispatch_attempted=True,native_maintenance_posts=None)
    completed=subprocess.run(command,input=encoded,capture_output=True,timeout=90)
    frame=b'\nWEREAD_WEB_AUTH_PRIVATE='
    if len(completed.stdout)>131072 or completed.stdout.count(frame)!=1:raise ValueError()
    result=json.loads(completed.stdout.split(frame)[1]);exit_code=completed.returncode;completed=None
    if type(result.get('posts')) is int and result['posts'] in (0,1):report['native_maintenance_posts']=result['posts']
    candidate=result.get('candidate')
    if not isinstance(candidate,dict) or result.get('posts')!=1 or not isinstance(candidate.get('cookies'),dict):raise ValueError()
    if candidate['cookies'].get('wr_vid')!=saved['vid']:raise ValueError()
    probe.cookies.clear()
    for name,value in candidate['cookies'].items():probe.set_cookie(name,value)
    probe.verify_account()
    retained={name:candidate[name] for name in ('wr_ticket','wr_wrpa') if candidate.get(name)}
    committed=store.finish_renewal(probe,pending,retained)
    return committed,{'native_receipt_verified':result.get('ok') is True and exit_code==0,'native_maintenance_posts':result.get('posts'),
                     'native_verification_reads':result.get('verification_reads'),'native_book_count':result.get('book_count')}


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--renew',action='store_true');parser.add_argument('--anonymous-control',action='store_true')
    parser.add_argument('--native-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.renew and not args.saved_session:parser.error('--renew requires --saved-session')
    if args.native_command is not None and not args.native_command:parser.error('--native-command cannot be empty')
    if args.native_command and not args.renew:parser.error('--native-command requires --renew')
    report={'result':'OFFLINE_ONLY','checked_at':datetime.now(timezone.utc).isoformat(),'account_data_writes':0,
            'credential_maintenance_posts':0,'credentials_written_to_files':False,'credentials_retained_until_goal_complete':True}
    if not args.saved_session:print(json.dumps(report,indent=2));return 0
    probe=MPProbe();saved={}
    try:
        store=SessionStore();saved=store.load();probe.vid=saved['vid']
        for name,value in saved['cookies'].items():probe.set_cookie(name,value)
        probe.verify_account();report['owner_profile_matches_pinned_vid']=True
        if args.anonymous_control:report['anonymous_account_control']=anonymous_account(probe.vid)
        if args.renew:
            if args.native_command:
                saved,native=native_renew(store,saved,probe,args.native_command,report);report.update(native)
            else:saved=probe.renew(store,saved)
            report.update(renewal_receipt_confirmed=True,pending_marker_cleared=True,
                ticket_present=bool(saved['web']['headers'].get('wr_ticket')),protection_header_present=bool(saved['web']['headers'].get('wr_wrpa')))
        shelf=probe.request('shelf','https://weread.qq.com/web/shelf/sync')
        books=shelf.get('books') if isinstance(shelf,dict) else None
        if not isinstance(books,list) or len(books)>5000:raise ValueError()
        probe.verify_account();report.update(result='WEB_RENEWAL_VERIFIED' if args.renew else 'WEB_AUTH_READ_VERIFIED',shelf_books=len(books))
        if args.native_command and not report.get('native_receipt_verified'):report.update(result='UNVERIFIED',reason='native_verification_failed')
        report['confirmed_cookie_rotation_saved']=save_refreshed_web_session(store,saved,probe)
    except Exception:report.update(result='UNVERIFIED',reason='web_credential_verification_failed')
    finally:
        report['credential_maintenance_posts']=(report.get('native_maintenance_posts') if args.native_command else int(probe.renewal_attempted));report['stages']=probe.report['stages']
        saved.clear();probe.close()
    print(json.dumps(report,indent=2));return 0 if report['result'] in ('WEB_RENEWAL_VERIFIED','WEB_AUTH_READ_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
