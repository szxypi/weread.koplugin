#!/usr/bin/env python3
"""Synthetic packaged first sync, real ReaderUI/workers/SQLite and offline reopen."""
import argparse,json,os,re,resource,subprocess,sys,tempfile,threading
from pathlib import Path
from native_initial_fixture import NativeInitialServer,MODES
from run_native_reader_position import FRAME,FLAGS,COUNTS
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate,run_child

CASES=MODES+('local_save_failed',)
CASE_FLAGS={'reopen','cancelled_locally','explicit_choice','confirmed','unknown_kept','reviewed','local_save_failed',
            'offline_preserved','no_automatic_write','workers_reaped'}


def decode(raw,mode,reopen=False):
    if mode not in CASES or type(reopen) is not bool or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('initial_reader/frame')
    v=json.loads(raw.split(FRAME)[1])
    if (not isinstance(v,dict) or set(v)!=FLAGS|set(COUNTS)|{'result','phase','initial_case'}
            or v['result'] not in ('PASS','UNVERIFIED') or v['phase'] not in ('init','complete')
            or any(type(v[k]) is not bool for k in FLAGS)
            or any(type(v[k]) is not int or not 0<=v[k]<=cap for k,cap in COUNTS.items())):raise ValueError('initial_reader/schema')
    c=v['initial_case']
    if (not isinstance(c,dict) or set(c)!=CASE_FLAGS|{'mode','failed_line'} or c['mode']!=mode or c['reopen']!=reopen
            or any(type(c[k]) is not bool for k in CASE_FLAGS) or type(c['failed_line']) is not int or not 0<=c['failed_line']<=10000):raise ValueError('initial_reader/case')
    if v['result']=='PASS':
        needed={'reopen','offline_preserved'} if reopen else {'cancelled_locally','explicit_choice','no_automatic_write','workers_reaped'}|(
            {'confirmed'} if mode in ('accepted','delayed') else {'reviewed','local_save_failed' if mode=='local_save_failed' else 'unknown_kept'})
        if (v['phase']!='complete' or v['failed_line'] or c['failed_line'] or v['web_posts'] or v['native_posts']!=(0 if reopen else 1)
                or {k for k in CASE_FLAGS if c[k]}!=needed):raise ValueError('initial_reader/incomplete')
    return v


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--case',choices=CASES,default='accepted');p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    a=p.parse_args(argv);runtime=a.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not all(1<=n<=4096 for n in (a.width,a.height,a.dpi))
            or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):p.error('bounded Linux runtime with tmpfs required')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    report=dict(result='UNVERIFIED',synthetic_only=True,account_data_posts=0,authentication_posts=0,stages=[],server_posts=0,
                profile_removed=False,offline_requests=0,installed=None,error='none',width=a.width,height=a.height,dpi=a.dpi)
    root=server=None
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-reader-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(a.candidate,profile/'plugins')
            server=NativeInitialServer('accepted' if a.case=='local_save_failed' else a.case)
            threading.Thread(target=server.serve_forever,daemon=True).start()
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
                     EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi),
                     WEREAD_NATIVE_READER_PORT=str(server.server_port),WEREAD_NATIVE_INITIAL_CASE=a.case)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/native_reader_position_probe.lua'
            for mode in ('initial','initial-reopen'):
                before=server.request_totals.copy()
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe),mode],env,b'',runtime,timeout=180)
                stage=decode(out,a.case,mode=='initial-reopen');report['stages'].append(stage)
                if mode=='initial-reopen':report['offline_requests']=sum((server.request_totals-before).values())
                if code or repaint or stage['result']!='PASS':raise ValueError('initial_reader/runtime')
            report['installed']=check_installed(a.candidate,profile);report['server_posts']=server.native_posts
            if server.native_posts!=1 or report['offline_requests']:raise ValueError('initial_reader/counts')
            report['result']='PASS'
    except subprocess.TimeoutExpired:report['error']='timeout'
    except Exception as error:report['error']=str(error) if re.fullmatch('initial_reader/[a-z_]+',str(error)) else 'runner'
    finally:
        if server:report['server_posts']=server.native_posts;server.shutdown();server.server_close()
        report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report,indent=2));return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
