#!/usr/bin/env python3
"""GET-only single completion-change planning. No --apply/write code path."""
import argparse
from datetime import datetime,timezone
import json
import subprocess
from urllib.parse import urlencode

from finish_change_contract import flags,make
from annotation_experiment_model import digest
from my_cloud_marks_model import identifier
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import NativeProbe,BASE


class Preview(NativeProbe):
    def __init__(self,opener=None):super().__init__(opener);self.grant=None;self.targets=set();self.gets=0
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed={BASE+'/shelf/sync'}|{BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)) for identity in self.targets}
        if body is not None or url not in allowed or self.grant!=digest(credentials) or self.gets>=12:raise ValueError('finish_change/read_scope')
        self.gets+=1;value=super().request(stage,url,credentials=credentials,timeout=timeout)
        if self.report['stages'][-1].get('status')!=200:raise ValueError('finish_change/http')
        return value
    def prepare(self,credentials):
        self.grant=digest(credentials);first=self.request('finish_change_shelf',BASE+'/shelf/sync',credentials=credentials);snapshot=flags(first);samples=[]
        for before in (False,True):
            candidates=sorted(identity for identity,row in snapshot.items() if identifier(identity) and row['finished']=={'value':before})
            selected=None
            for identity in candidates[:3]:
                self.targets.add(identity)
                progress=self.request('finish_change_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials)
                try:plan=make(first,progress,identity,not before)
                except ValueError:continue
                selected=dict(book_id=identity,desired=not before,progress=progress,plan=plan);break
            if selected is None:raise ValueError('finish_change/selection')
            samples.append(selected)
        second=self.request('finish_change_independent_shelf',BASE+'/shelf/sync',credentials=credentials)
        if flags(second)!=snapshot:raise ValueError('finish_change/changed')
        for sample in samples:
            progress=self.request('finish_change_independent_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=sample['book_id'])),credentials=credentials)
            if make(second,progress,sample['book_id'],sample['desired'])!=sample['plan']:raise ValueError('finish_change/changed')
        return dict(shelf=first,samples=samples)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session:parser.error('comparison requires saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,private_files=False)
    credentials={};probe=None
    try:
        if args.saved_session:
            credentials=NativeSessionStore().load(SessionStore().load()['vid']);probe=Preview();payload=probe.prepare(credentials)
            if args.lua_command:
                frame=b'\nWEREAD_FINISH_CHANGE_RESULT='
                child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=60)
                if child.returncode or len(child.stdout)>1024*1024 or child.stdout.count(frame)!=1:raise ValueError('finish_change/lua')
                if json.loads(child.stdout.split(frame)[1])!=[row['plan'] for row in payload['samples']]:raise ValueError('finish_change/different')
                report['lua_matches']=True
            report.update(result='FINISH_CHANGE_READ_ONLY_PLANS_VERIFIED',plans=2,finished_plan=True,unfinished_plan=True,shelf_books=len(flags(payload['shelf'])),original_state_unchanged=True)
    except Exception:report.update(result='UNVERIFIED',reason='finish_change_preflight_failed')
    finally:
        if probe:report.update(gets=probe.gets,stages=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in probe.report['stages']])
        credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
