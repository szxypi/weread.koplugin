#!/usr/bin/env python3
"""Run an exact-row, no-network native preview in a disposable tmpfs profile."""
import argparse
import base64
import json
import os
from pathlib import Path
import resource
import sqlite3
import hashlib
import sys
import tempfile

from native_time_capture import validate, MAX_ARCHIVE
from run_persistent_ui_probe import extract_candidate, run_child

FRAME=b'\nWEREAD_NATIVE_TIME_RESTORE_RESULT='


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--synthetic-tracked',action='store_true')
    args=parser.parse_args(argv)
    runtime=args.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file()
            or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux KOReader and tmpfs required')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report={'result':'UNVERIFIED','profile_removed':False,'account_data_posts':0,'authentication_posts':0}
    root=None
    stage='input'
    try:
        raw=sys.stdin.buffer.read(4*MAX_ARCHIVE+65536)
        if len(raw)>=4*MAX_ARCHIVE+65536:raise ValueError('preview_input')
        plan=validate(json.loads(raw));stage='prepare';archive=base64.b64decode(plan['archive_base64'],validate=True)
        if args.synthetic_tracked and (plan['owner'],plan['book_id'],plan['chapter_uid'])!=('900000','900001','2'):
            raise ValueError('preview_synthetic')
        private={key:value for key,value in plan.items() if key!='archive_base64'}
        with tempfile.TemporaryDirectory(prefix='weread-time-restore-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
            extract_candidate(args.candidate,plugins)
            epub=root/'source.epub';epub.write_bytes(archive);os.chmod(epub,0o600)
            ledger=root/'ledger';ledger.mkdir(mode=0o700)
            env=dict(os.environ,KO_HOME=str(profile),TZ='Asia/Shanghai',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/native_time_restore_preview.lua'
            command=[str(runtime/'luajit'),str(probe),str(plugins/'weread.koplugin'),str(ledger),str(epub)]
            if args.synthetic_tracked:command.append('synthetic')
            stage='native'
            code,out,repaint=run_child(command,env,json.dumps(private,separators=(',',':')).encode(),runtime,timeout=60)
            if code or repaint or out.count(FRAME)!=1:raise ValueError('preview_child')
            value=json.loads(out.split(FRAME)[1])
            fields={'result','seconds','exact_saved_rows','archive_identity_verified','fresh_coverage_rejects_old_rows',
                    'pending_unchanged','account_data_posts','authentication_posts'}
            if (not isinstance(value,dict) or set(value)!=fields or value['result']!=('SYNTHETIC_TRACKED' if args.synthetic_tracked else 'SAFE_UNTRACKED')
                    or value['seconds']!=plan['seconds'] or any(value[k] is not True for k in
                       ('exact_saved_rows','archive_identity_verified','pending_unchanged'))
                    or value['fresh_coverage_rejects_old_rows'] is args.synthetic_tracked
                    or any(type(value[k]) is not int or value[k]!=0 for k in ('account_data_posts','authentication_posts'))):
                raise ValueError('preview_result')
            if args.synthetic_tracked:
                stage='evidence'
                from native_time_capture_evidence import PROTOCOL, account_key, validate_evidence
                def snapshot(path):
                    source=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True)
                    backup=path.with_suffix('.snapshot')
                    target=sqlite3.connect(str(backup))
                    try:
                        source.backup(target)
                        if target.execute('PRAGMA journal_mode=DELETE').fetchone()!=('delete',):raise ValueError('preview_snapshot')
                    finally:source.close();target.close()
                    return backup.read_bytes()
                led=snapshot(ledger/('offline-time-'+account_key(plan['owner'])+'.db'))
                cov=snapshot(ledger/'reading-time-coverage.db')
                evidence=dict(protocol=PROTOCOL,ledger_base64=base64.b64encode(led).decode(),ledger_sha256=hashlib.sha256(led).hexdigest(),
                    coverage_base64=base64.b64encode(cov).decode(),coverage_sha256=hashlib.sha256(cov).hexdigest())
                report['synthetic_sqlite_header_modes']=[list(led[18:20]),list(cov[18:20])]
                validate_evidence(plan,evidence)
                value['sqlite_evidence_verified']=True
            report.update(value)
    except Exception as error:
        report['result']='UNVERIFIED'
        if args.synthetic_tracked:
            report['synthetic_failure_stage']=stage;report['synthetic_failure_type']=type(error).__name__
            if str(error) in ('capture_evidence/database','capture_evidence/ledger','capture_evidence/coverage'):report['synthetic_failure_reason']=str(error)
    finally:
        report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report))
    return int(report['result']!=('SYNTHETIC_TRACKED' if args.synthetic_tracked else 'SAFE_UNTRACKED') or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
