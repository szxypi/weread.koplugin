#!/usr/bin/env python3
"""Opt-in synthetic native finished-mark UI, no public Internet/account."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile
from run_persistent_ui_probe import extract_candidate,run_child

FRAME=b'\nWEREAD_FINISH_UI_RESULT='


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);repo=Path(__file__).resolve().parent.parent
    candidate=root/'candidate.zip';subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(candidate)],check=True,capture_output=True)
    report=dict(result='UNVERIFIED',profile_removed=False,installed_bytes_match=False,stages=[])
    temporary=None
    try:
        with tempfile.TemporaryDirectory(prefix='weread-finish-',dir='/dev/shm') as temporary:
            profile=Path(temporary)/'profile';(profile/'plugins').mkdir(parents=True);xdg=Path(temporary)/'xdg';xdg.mkdir(mode=0o700)
            extract_candidate(candidate,profile/'plugins');shots=root/'screenshots';shots.mkdir()
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_FINISH_SHOTS=str(shots))
            code,out,repaint=run_child([str(args.koreader.resolve()/'luajit'),str(repo/'spec/koreader/finish_change_store_smoke.lua'),
                str(profile/'plugins/weread.koplugin'),str(Path(temporary)/'finish-store-smoke')],env,b'',args.koreader.resolve(),timeout=60)
            if code or repaint or b'PASS: finished-mark SQLite FULL, rollback and fork claim' not in out:raise ValueError('finish_store')
            report['finish_store_verified']=True
            code,out,repaint=run_child([str(args.koreader.resolve()/'luajit'),str(repo/'spec/koreader/finish_queue_store_smoke.lua'),
                str(profile/'plugins/weread.koplugin'),str(Path(temporary)/'queue-smoke')],env,b'',args.koreader.resolve(),timeout=60)
            if code or repaint or b'PASS: offline finished-mark queue SQLite' not in out:raise ValueError('queue_store')
            report['queue_store_verified']=True
            code,out,repaint=run_child([str(args.koreader.resolve()/'luajit'),str(repo/'spec/koreader/membership_queue_store_smoke.lua'),
                str(profile/'plugins/weread.koplugin'),str(Path(temporary)/'membership-queue-smoke')],env,b'',args.koreader.resolve(),timeout=60)
            if code or repaint or b'PASS: offline membership queue SQLite' not in out:raise ValueError('membership_queue_store')
            report['membership_queue_store_verified']=True
            for mode in ('guard','exclusive'):
                code,out,repaint=run_child([str(args.koreader.resolve()/'luajit'),str(repo/'spec/koreader/finish_store_contention_probe.lua'),
                    str(profile/'plugins/weread.koplugin'),str(Path(temporary)/('contention-'+mode)),mode],
                    env,b'',args.koreader.resolve(),timeout=60)
                if code or repaint:raise ValueError('journal_contention_'+mode)
                counts=json.loads(out.splitlines()[-1])
                if counts.get('success')!=(1 if mode=='guard' else 0) or counts.get('storage')!=(0 if mode=='guard' else 1):
                    raise ValueError('journal_contention_'+mode)
                report['journal_contention_'+mode+'_verified']=True
            for mode in ('live','reopen','offline_reopen','retry_reopen'):
                code,out,repaint=run_child([str(args.koreader.resolve()/'luajit'),str(repo/'spec/koreader/finish_change_ui_probe.lua'),mode],env,b'',args.koreader.resolve(),timeout=300)
                if len(out)>4*1024*1024 or out.count(FRAME)!=1:raise ValueError('native_frame')
                stage=json.loads(out.split(FRAME)[1]);report['stages'].append(stage)
                if code or repaint or stage['result']!='PASS':raise ValueError('native_acceptance')
                if mode=='reopen' and (stage.get('local_storage_retry_verified') is not True
                        or stage.get('dialog_retry_verified') is not True
                        or stage.get('paused_preflight_verified') is not True):
                    raise ValueError('local_storage_retry')
                if mode=='retry_reopen' and (stage.get('trace_commit')!='confirmed'
                        or stage.get('trace_attempted') is not True or stage.get('trace_finished') is not True):
                    raise ValueError('restart_confirmation')
            with zipfile.ZipFile(candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir():assert (profile/'plugins'/item.filename).read_bytes()==archive.read(item)
            report.update(result='PASS',installed_bytes_match=True)
    except Exception:pass
    finally:
        report['profile_removed']=temporary is not None and not Path(temporary).exists()
        (root/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report));return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
