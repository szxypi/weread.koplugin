#!/usr/bin/env python3
"""Verify the real-account KOReader cloud-pin preview with writes blocked."""
import argparse
from copy import deepcopy
import json
import re
import secrets
import subprocess
from urllib.parse import urlencode
from finish_change_contract import flags,position_hash
from native_trial_pipe import Frames,stop,write_initial
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import position,state_hash
from verify_cloud_pin_model import Probe as ReadProbe,plans
from verify_eink_login import BASE,NativeProbe
from verify_native_finish_trial import validate_result
from verify_native_metadata import normalize_native


class PreviewFailure(ValueError):
    def __init__(self,result):
        super().__init__('cloud_pin_preview/child');self.result=result


class Probe(ReadProbe):
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed={BASE+'/shelf/sync'}
        if self.target:
            allowed.update(BASE+'/book/'+route+'?'+urlencode({'bookId':self.target}) for route in ('getProgress','info'))
        if body is not None or url not in allowed:raise ValueError('cloud_pin_preview/read_scope')
        return NativeProbe.request(self,stage,url,credentials=credentials,timeout=timeout)


def prepare(probe,credentials):
    shelf=probe.request('shelf',BASE+'/shelf/sync',credentials=credentials);rows=flags(shelf);bound=None
    candidates=sorted(identity for identity,row in rows.items() if re.fullmatch('[1-9][0-9]{0,19}',identity)
        and (row['pinned']=={'reason':'missing'} or row['pinned']=={'value':False}))
    for identity in candidates[:20]:
        probe.target=identity
        progress=probe.request('position',BASE+'/book/getProgress?'+urlencode({'bookId':identity}),credentials=credentials)
        try:bound=plans(shelf,progress,identity);break
        except ValueError:continue
    if bound is None:raise ValueError('cloud_pin_preview/no_candidate')
    metadata=normalize_native(probe.request('metadata',BASE+'/book/info?'+urlencode({'bookId':identity}),credentials=credentials),identity)
    baseline=dict(shelf=state_hash(shelf),position=position_hash(position(progress,identity)))
    payload=dict(credentials=credentials,book_id=identity,expected_metadata=metadata,shelf_books=len(rows),
                 mark=deepcopy(bound[0]),restore=deepcopy(bound[1]))
    check(probe,credentials,baseline)
    return baseline,payload


def check(probe,credentials,baseline):
    shelf=probe.request('independent_shelf',BASE+'/shelf/sync',credentials=credentials)
    progress=probe.request('independent_position',BASE+'/book/getProgress?'+urlencode({'bookId':probe.target}),credentials=credentials)
    if (state_hash(shelf)!=baseline['shelf'] or position_hash(position(progress,probe.target))!=baseline['position']):
        raise ValueError('cloud_pin_preview/changed')
    return True


def run(probe,credentials,baseline,payload,command,current):
    if not command or any(not isinstance(value,str) or not value for value in command):raise ValueError('cloud_pin_preview/command')
    current();check(probe,credentials,baseline)
    bound=deepcopy(payload);bound.update(permit_writes=False,rpc_token=secrets.token_hex(16))
    child=None
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,bound);frames=Frames(child.stdout,bound['rpc_token'],timeout=260)
        kind,value=frames.next()
        if kind!='RESULT':raise ValueError('cloud_pin_preview/unexpected_step')
        result=validate_result(value,False)
        if child.wait(timeout=15) or result['result']!='PASS' or result['stage']['shelf_books']!=bound['shelf_books']:
            raise PreviewFailure(result)
        current();check(probe,credentials,baseline)
        return dict(result='OWNER_NATIVE_PIN_PREVIEW_VERIFIED',native_ui=result,
                    original_flags_groups_and_exact_position_unchanged=True,account_data_writes=0,authentication_posts=0)
    finally:
        if child is not None:stop(child)
        bound.clear()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.native_command and not args.saved_session:parser.error('--native-command requires --saved-session')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,credentials_written_to_files=False)
    saved=credentials=payload=None;probe=Probe()
    try:
        if args.saved_session:
            from verify_native_thought_trial import other_pending
            if other_pending():raise ValueError('cloud_pin_preview/pending')
            saved=SessionStore().load();owner=saved['vid'];credentials=NativeSessionStore().load(owner)
            baseline,payload=prepare(probe,credentials)
            def current():
                if SessionStore().load()['vid']!=owner or NativeSessionStore().load(owner)!=credentials:raise ValueError('cloud_pin_preview/session')
            if args.native_command:report.update(run(probe,credentials,baseline,payload,args.native_command,current))
            else:current();check(probe,credentials,baseline);report.update(result='READ_ONLY_PREVIEW_READY',shelf_books=payload['shelf_books'])
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        if isinstance(error,PreviewFailure):report['native_ui']=error.result
        elif str(error) in {'cloud_pin_preview/no_candidate','cloud_pin_preview/changed','cloud_pin_preview/session',
                            'cloud_pin_preview/pending','cloud_pin_preview/unexpected_step','trial_pipe/eof','trial_pipe/frame'}:
            report['detail']=str(error)
    finally:
        report['host_stages']=[{k:row[k] for k in ('stage','status') if k in row} for row in probe.report['stages']]
        probe.target=None
        if payload:payload.clear()
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
