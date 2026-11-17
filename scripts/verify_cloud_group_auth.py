#!/usr/bin/env python3
"""Read-only compatibility check for the saved Web session on the client shelf.

The referenced client group-management protocol uses vid/skey rather than the
E-Ink access token. This probe sends only a fixed shelf GET, never a write.
"""
import argparse
import json
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener

from cloud_group_contract import project
from cloud_group_trial import _cross_channel
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import NativeProbe, NoRedirect
from verify_shelf_flags import WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session
from verify_cloud_group_trial import FULL_SHELF


class WebKeyShelf:
    def __init__(self, opener=None): self.opener=opener or build_opener(NoRedirect())

    def read(self, owner, key):
        if (not isinstance(owner,str) or not owner.isascii() or not owner.isdigit()
                or not isinstance(key,str) or not 1<=len(key)<=4096
                or any(ord(c)<33 or ord(c)>126 or c in '\r\n' for c in key)):
            raise ValueError('cloud_group_auth/credentials')
        req=Request(FULL_SHELF,headers={'vid':owner,'skey':key,'v':'10.2.1.87',
            'User-Agent':'WeRead/10.2.1 (iPad; iOS 26.5; Scale/2.00)','Accept':'application/json'})
        with self.opener.open(req,timeout=15) as response:
            raw=response.read(4*1024*1024+1)
            if response.status!=200 or len(raw)>4*1024*1024:raise ValueError('cloud_group_auth/response')
            value=json.loads(raw)
        if not isinstance(value,dict):raise ValueError('cloud_group_auth/response')
        for field in ('errcode','errCode'):
            if value.get(field,0) not in (0,None):raise ValueError('cloud_group_auth/rejected')
        return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,private_values_saved=False)
    saved=grant=web=None
    try:
        if args.saved_session:
            store=SessionStore();saved=store.load();owner=saved['vid'];grant=NativeSessionStore().load(owner)
            web=WebFlagsProbe();web.vid=owner
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();native=NativeProbe()
            expected=project(native.request('shelf_full',FULL_SHELF,credentials=grant))
            observed=project(WebKeyShelf().read(owner,saved['cookies'].get('wr_skey')))
            if not _cross_channel(expected,observed):raise ValueError('cloud_group_auth/mismatch')
            web.verify_account();report.update(result='WEB_KEY_SHELF_READ_VERIFIED',same_owner_verified=True,
                group_membership_matches_native=True,web_rotation_saved=save_refreshed_web_session(store,saved,web))
    except HTTPError as exc:
        report.update(result='UNVERIFIED',reason='http_rejection',http_status=exc.code);exc.close()
    except (URLError,ValueError,KeyError,TypeError):report.update(result='UNVERIFIED',reason='read_unavailable')
    except Exception:report.update(result='UNVERIFIED',reason='read_unavailable')
    finally:
        if web:web.close()
        if grant:grant.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','WEB_KEY_SHELF_READ_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
