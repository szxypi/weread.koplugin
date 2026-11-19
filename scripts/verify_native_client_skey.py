#!/usr/bin/env python3
"""Check whether one native login renewal supplies usable client credentials.

Offline by default. Explicit renewal consumes the existing durable renewal
intent and sends at most one authentication request. The optional skey stays
in memory and can only be used for a fixed read-only shelf request.
"""
import argparse
import json
import resource
from urllib.error import HTTPError

from cloud_group_contract import project
from cloud_group_trial import _cross_channel
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_cloud_group_auth import AndroidKeyShelf, WebKeyShelf
from verify_cloud_group_trial import FULL_SHELF
from verify_eink_login import NativeProbe
from verify_eink_renewal import RenewalProbe


class CaptureProbe(RenewalProbe):
    def __init__(self,opener=None):
        super().__init__(opener);self.client_key=None

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        value=super().request(stage,url,body,credentials,timeout)
        if stage=='renewal':
            key=value.get('skey')
            if isinstance(key,str) and 1<=len(key)<=4096 and all(33<=ord(c)<=126 for c in key):
                self.client_key=key
        return value


def execute(store,owner,previous,probe,client,native):
    report=dict(result='UNVERIFIED',authentication_posts=0,account_data_posts=0,client_key_present=False)
    receipt=renewed=None
    try:
        receipt,previous=store.begin_renewal(owner,previous)
        renewed,_shelf=probe.renew(previous)
        store.finish_renewal(receipt,renewed,verified=True)
        if store.load(owner)!=renewed:raise ValueError('renewal_readback')
        report.update(result='CLIENT_KEY_ABSENT',renewal_saved=True,client_key_present=probe.client_key is not None)
        if probe.client_key is not None:
            try:
                expected=project(native.request('shelf',FULL_SHELF,credentials=renewed))
                observed=project(client.read(owner,probe.client_key))
                if not _cross_channel(expected,observed):raise ValueError('shelf_mismatch')
                if store.load(owner)!=renewed:raise ValueError('renewal_changed')
                report.update(result='CLIENT_KEY_READ_VERIFIED',same_owner_shelf=True)
            except HTTPError as error:
                report.update(result='CLIENT_KEY_REJECTED',http_status=error.code);error.close()
            except Exception:
                report.update(result='CLIENT_KEY_UNVERIFIED')
    except Exception:
        report.update(result='RENEWAL_UNVERIFIED')
    finally:
        attempted=probe.report.get('renewal_attempts',0)
        report['authentication_posts']=attempted
        if receipt and attempted==0:
            try:store.release_renewal(receipt,not_dispatched=True)
            except Exception:pass
        probe.client_key=None
        if previous:previous.clear()
        if renewed:renewed.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--renew-and-check',action='store_true')
    parser.add_argument('--android-profile',action='store_true',help='Check the fixed Android client profile instead of the desktop profile')
    args=parser.parse_args(argv)
    if args.saved_session!=args.renew_and_check:parser.error('both explicit options are required')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report=dict(result='OFFLINE_ONLY',authentication_posts=0,account_data_posts=0)
    try:
        if args.saved_session:
            owner=SessionStore().load()['vid'];store=NativeSessionStore();previous=store.load(owner)
            report=execute(store,owner,previous,CaptureProbe(),AndroidKeyShelf() if args.android_profile else WebKeyShelf(),NativeProbe())
            report['profile']='android' if args.android_profile else 'desktop'
    except Exception:report.update(result='UNVERIFIED')
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','CLIENT_KEY_ABSENT','CLIENT_KEY_REJECTED','CLIENT_KEY_READ_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
