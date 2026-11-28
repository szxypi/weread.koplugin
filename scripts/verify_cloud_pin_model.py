#!/usr/bin/env python3
"""Read-only real shelf/position parity check against KOReader Lua pin plans."""
import argparse
from copy import deepcopy
import json
import re
import subprocess
from urllib.parse import urlencode
from cloud_pin_contract import make
from finish_change_contract import flags,position_hash
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash,position
from verify_eink_login import BASE,NativeProbe


class Probe(NativeProbe):
    def __init__(self):super().__init__();self.target=None
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed={BASE+'/shelf/sync'}
        if self.target:allowed.add(BASE+'/book/getProgress?'+urlencode({'bookId':self.target}))
        if body is not None or url not in allowed:raise ValueError('cloud_pin/read_scope')
        return super().request(stage,url,credentials=credentials,timeout=timeout)


def plans(shelf,progress,identity):
    first=make(shelf,progress,identity,True);changed=deepcopy(shelf)
    next(row for row in changed['books'] if str(row['bookId'])==identity)['isTop']=1
    second=make(changed,progress,identity,False)
    return [first['metadata'],second['metadata']]


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session:parser.error('--lua-command requires --saved-session')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,credentials_written_to_files=False)
    saved=credentials=None;probe=Probe()
    try:
        if args.saved_session:
            from verify_native_thought_trial import other_pending
            if other_pending():raise ValueError('cloud_pin/pending')
            saved=SessionStore().load();owner=saved['vid'];credentials=NativeSessionStore().load(owner)
            shelf=probe.request('shelf',BASE+'/shelf/sync',credentials=credentials);rows=flags(shelf)
            candidates=sorted(identity for identity,row in rows.items() if re.fullmatch('[1-9][0-9]{0,19}',identity)
                and (row['pinned']=={'reason':'missing'} or row['pinned']=={'value':False}))
            bound=None
            for identity in candidates[:20]:
                probe.target=identity
                point=probe.request('progress',BASE+'/book/getProgress?'+urlencode({'bookId':identity}),credentials=credentials)
                try:bound=plans(shelf,point,identity);break
                except ValueError:continue
            if bound is None:raise ValueError('cloud_pin/no_candidate')
            shelf2=probe.request('shelf_check',BASE+'/shelf/sync',credentials=credentials)
            point2=probe.request('progress_check',BASE+'/book/getProgress?'+urlencode({'bookId':probe.target}),credentials=credentials)
            if state_hash(shelf)!=state_hash(shelf2) or position_hash(position(point,probe.target))!=position_hash(position(point2,probe.target)):
                raise ValueError('cloud_pin/changed')
            if NativeSessionStore().load(owner)!=credentials or SessionStore().load()['vid']!=owner:raise ValueError('cloud_pin/session')
            report.update(result='READ_ONLY_PLAN_VERIFIED',shelf_books=len(rows),original_pin_provided=bound[0]['before']!='missing',
                          state_and_position_stable=True,lua_model_matches=False)
            if args.lua_command:
                payload=dict(shelf=shelf,progress=point,book_id=probe.target)
                child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=60)
                frame=b'\nWEREAD_CLOUD_PIN_MODEL='
                if child.returncode or len(child.stdout)>1024*1024 or child.stdout.count(frame)!=1:raise ValueError('cloud_pin/lua')
                if json.loads(child.stdout.split(frame)[1])!=bound:raise ValueError('cloud_pin/model_differs')
                report['lua_model_matches']=True
    except (Exception,KeyboardInterrupt):report['result']='UNVERIFIED'
    finally:
        report['stages']=[{k:row[k] for k in ('stage','status') if k in row} for row in probe.report['stages']]
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
