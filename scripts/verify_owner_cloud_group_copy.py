#!/usr/bin/env python3
"""Read-only real shelf projection through an isolated offline native UI."""
import argparse,json,resource,subprocess
from native_shelf_renewal_broker import shelf_projection
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_native_time_guarded_dry import trusted_command
from verify_eink_login import NativeProbe,BASE
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import WebSourceProbe,BASE as WEB


def prepare(shelf):
    """Independent, bounded list of ordinary IDs; never include credentials."""
    shelf_projection(shelf);books=[];archives=[];expected=[];labels=set()
    for row in shelf['books']:
        books.append(dict(bookId=str(row['bookId']),title=row['title']))
    for row in shelf['archive']:
        ident=str(row['archiveId']);label=row['name'].strip(' \t\r\n\v\f') or '未命名分组'
        ids=[str(item) for item in row['bookIds']]
        archives.append(dict(archiveId=ident,name=row['name'],bookIds=ids))
        members=list(dict.fromkeys(item for item in ids if not item.startswith('MP_WXS_')))
        if ids and not members:continue
        if label in labels:raise ValueError('owner_copy/ambiguous')
        labels.add(label);expected.append(dict(label=label,members=members))
    if not 1<=len(expected)<=100 or sum(len(row['members']) for row in expected)>10000:
        raise ValueError('owner_copy/limit')
    return dict(books=books,archives=archives,expected=expected)


def command(width,height,dpi):
    known=trusted_command();index=known.index('--candidate')
    if index+2!=len(known):raise ValueError('owner_copy/command')
    return known[:6]+['python3','scripts/run_owner_cloud_group_copy.py','--koreader','/validation/runtime/lib/koreader',
        '--candidate',known[index+1],'--width',str(width),'--height',str(height),'--dpi',str(dpi)]


def run():
    report=dict(result='UNVERIFIED',account_data_posts=0,authorization_posts=0,private_data_in_report=False)
    session=store=web=saved=grant=None
    try:
        session=SessionStore();saved=session.load();store=NativeSessionStore();grant=store.load(saved['vid'])
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account()
        if save_refreshed_web_session(session,saved,web):saved.clear();saved=session.load()
        baseline=web.request('shelf',WEB+'/web/shelf/sync');native=NativeProbe().request('shelf',BASE+'/shelf/sync',credentials=grant)
        if shelf_projection(baseline)!=shelf_projection(native):raise ValueError('owner_copy/channels')
        expected=prepare(baseline);before_web=state_hash(baseline);before_native=state_hash(native)
        raw=json.dumps(expected,ensure_ascii=False).encode()
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            child=subprocess.run(command(width,height,dpi),input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=420,check=True)
            result=json.loads(child.stdout)
            if result!=dict(result='PASS',profile_removed=True,private_data_in_report=False,network_requests=0,
                    groups=len(expected['expected']),offline_reopen=True):raise ValueError('owner_copy/ui')
        after_web=web.request('shelf',WEB+'/web/shelf/sync');after_native=NativeProbe().request('shelf',BASE+'/shelf/sync',credentials=grant)
        if (state_hash(after_web)!=before_web or state_hash(after_native)!=before_native
                or shelf_projection(after_web)!=shelf_projection(after_native) or store.load(saved['vid'])!=grant):
            raise ValueError('owner_copy/changed')
        report.update(result='OWNER_CLOUD_GROUP_COPY_UI_VERIFIED',groups=len(expected['expected']),
            regular_memberships=sum(len(row['members']) for row in expected['expected']),
            sizes=2,offline_reopen=True,temporary_profiles_removed=True,shelf_unchanged=True)
    except Exception:
        pass
    finally:
        if web and saved and session:
            try:save_refreshed_web_session(session,saved,web)
            except Exception:report['result']='UNVERIFIED'
        if web:web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    if not args.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authorization_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));report=run();print(json.dumps(report));return int(report['result']!='OWNER_CLOUD_GROUP_COPY_UI_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
