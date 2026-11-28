#!/usr/bin/env python3
"""Real account notebook search through isolated native UI and offline restart."""
import argparse
import json
import resource
import subprocess

from native_shelf_renewal_broker import shelf_projection
from notebook_catalog_model import project
from owner_notebook_search_cases import prepare
from run_notebook_catalog_ui import FRAME, validate_stage
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_native_time_guarded_dry import trusted_command
from verify_eink_login import BASE, NativeProbe
from verify_notebook_catalog import Probe
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB, WebSourceProbe


def command(width,height,dpi):
    known=trusted_command();index=known.index('--candidate')
    if index+2!=len(known):raise ValueError('owner_notebook_search/command')
    return known[:6]+['xvfb-run','-a','python3','scripts/run_notebook_catalog_ui.py','--koreader','/validation/runtime/lib/koreader',
        '--candidate',known[index+1],'--width',str(width),'--height',str(height),'--dpi',str(dpi),'--owner-search']


def verify_response(child,expected):
    if child.returncode or len(child.stdout)>12*1024*1024 or child.stdout.count(FRAME)!=1:
        raise ValueError('owner_notebook_search/frame')
    value=json.loads(child.stdout.split(FRAME)[1]);ui=value.get('ui') if isinstance(value,dict) else None
    if (not isinstance(value,dict) or set(value)!={'model','native','requests','ui'} or value['model']!=expected
            or value['native']!=expected or value['requests']!=1 or not isinstance(ui,dict)
            or set(ui)!={'result','profile_removed','installed_bytes_match','installed_files','stages'}
            or ui['result']!='PASS' or ui['profile_removed'] is not True or ui['installed_bytes_match'] is not True
            or type(ui['installed_files']) is not int or not 1<=ui['installed_files']<=1000
            or not isinstance(ui['stages'],list) or len(ui['stages'])!=2):raise ValueError('owner_notebook_search/result')
    for stage,mode in zip(ui['stages'],('live','reopen')):
        validate_stage(stage,mode,len(expected['books']),owner_search=True)
    return True


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
        if shelf_projection(baseline)!=shelf_projection(native):raise ValueError('owner_notebook_search/channels')
        before_web,before_native=state_hash(baseline),state_hash(native)
        probe=Probe();source=probe.read(grant,100);expected=project(source,1);cases=prepare(expected)
        payload=dict(source=source,owner=saved['vid'],now=1,credentials=grant,search_cases=cases)
        raw=json.dumps(payload,ensure_ascii=False).encode()
        if len(raw)>8*1024*1024:raise ValueError('owner_notebook_search/size')
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            child=subprocess.run(command(width,height,dpi),input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=420)
            verify_response(child,expected)
        if project(probe.read(grant,100),1)!=expected:raise ValueError('owner_notebook_search/changed')
        after_web=web.request('shelf',WEB+'/web/shelf/sync');after_native=NativeProbe().request('shelf',BASE+'/shelf/sync',credentials=grant)
        if (state_hash(after_web)!=before_web or state_hash(after_native)!=before_native
                or shelf_projection(after_web)!=shelf_projection(after_native) or store.load(saved['vid'])!=grant):
            raise ValueError('owner_notebook_search/changed')
        report.update(result='OWNER_NOTEBOOK_SEARCH_UI_VERIFIED',notebooks=len(expected['books']),search_cases=len(cases),
            sizes=2,offline_reopen=True,shelf_and_notebook_unchanged=True,temporary_profiles_removed=True)
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
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));report=run();print(json.dumps(report));return int(report['result']!='OWNER_NOTEBOOK_SEARCH_UI_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
