#!/usr/bin/env python3
"""Supervise a packaged public-account UI trial in a disposable tmpfs profile."""
import argparse,json,os,re,signal,subprocess,sys,tempfile
from pathlib import Path
from mp_subscription_trial import valid_id
from native_trial_pipe import Frames,read_initial,reply,write_initial
from run_native_thought_trial import read_reply,stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate
from verify_eink_renewal import validate_credentials

FLAGS={'permit_writes','chooser','preview','cancel_no_post','heartbeat','cache_verified','journal_before_posts',
       'local_import_preserved','credential_audit','guard_selftest'}
COUNTS={'native_gets':16,'adds':1,'removes':1,'denied':0,'screenshots':0,'failed_line':10000}


def validate_stage(value,armed):
    if (not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'result','phase'} or value['result']!='PASS' or value['phase']!='complete'
            or value['permit_writes'] is not armed or any(type(value[k]) is not bool for k in FLAGS)
            or any(type(value[k]) is not int or not 0<=value[k]<=v for k,v in COUNTS.items())
            or not all(value[k] for k in ('chooser','preview','cancel_no_post','heartbeat','local_import_preserved','credential_audit','guard_selftest'))
            or any(value[k] is not armed for k in ('cache_verified','journal_before_posts'))
            or value['failed_line'] or value['native_gets']<(3 if armed else 1)
            or any(value[k]!=(1 if armed else 0) for k in ('adds','removes'))):raise ValueError('mp_subscription_ui/stage')
    return value


def validate_input(value,armed,mock_port):
    fields={'credentials','account_id','review_id','shelf_books','members_digest','rpc_token','permit_writes'}|({'mock_port'} if mock_port is not None else set())
    if (not isinstance(value,dict) or set(value)!=fields or value['permit_writes'] is not armed or value.get('mock_port')!=mock_port
            or not valid_id(value['account_id']) or not isinstance(value['review_id'],str)
            or not value['review_id'].startswith(value['account_id']+'_') or not re.fullmatch(r'MP_WXS_[1-9][0-9]{0,19}_[A-Za-z0-9_-]{1,128}',value['review_id'])
            or not isinstance(value['rpc_token'],str) or re.fullmatch('[a-f0-9]{32}',value['rpc_token']) is None
            or not isinstance(value['members_digest'],str) or re.fullmatch('[a-f0-9]{64}',value['members_digest']) is None
            or type(value['shelf_books']) is not int or not 1<=value['shelf_books']<=5000):raise ValueError('mp_subscription_ui/input')
    validate_credentials(value['credentials'])
    if mock_port is not None and (value['account_id']!='MP_WXS_900098' or value['review_id']!='MP_WXS_900098_synthetic'
            or value['credentials']!=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',
                deviceId='eink334691225'+'1'*19)):raise ValueError('mp_subscription_ui/mock')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--armed',action='store_true');parser.add_argument('--mock-port',type=int);args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(args.width,args.height,args.dpi)<=max(args.width,args.height,args.dpi)<=4096:parser.error('bounded Linux runtime required')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid mock port')
    if not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    def interrupt(_signal,_frame):raise RuntimeError('mp_subscription_ui/interrupted')
    signal.signal(signal.SIGTERM,interrupt)
    payload=root=child=None;result=dict(result='UNVERIFIED',profile_removed=False,installed=None,stage=None)
    try:
        payload=read_initial(sys.stdin.buffer);validate_input(payload,args.armed,args.mock_port)
        with tempfile.TemporaryDirectory(prefix='weread-mp-subscription-ui-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),LD_LIBRARY_PATH=str(runtime/'libs'),SDL_VIDEODRIVER='dummy',
                EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),
                EMULATE_READER_DPI=str(args.dpi),WEREAD_MP_SUBSCRIPTION_UI_ARMED='1' if args.armed else '0')
            env.pop('WEREAD_MP_SUBSCRIPTION_UI_MOCK_PORT',None)
            if args.mock_port is not None:env['WEREAD_MP_SUBSCRIPTION_UI_MOCK_PORT']=str(args.mock_port)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_mp_subscription_ui_probe.lua'
            child=subprocess.Popen([str(runtime/'luajit'),str(probe)],env=env,cwd=runtime,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['rpc_token'],timeout=180)
                while True:
                    kind,value=frames.next()
                    if kind=='RESULT':result['stage']=value;break
                    sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(value,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
                    reply(child.stdin,read_reply(sys.stdin.buffer))
                if child.wait(timeout=10):raise ValueError('mp_subscription_ui/child')
                validate_stage(result['stage'],args.armed)
            finally:stop_reader(child);child=None
            result.update(result='PASS',installed=check_installed(args.candidate,profile))
    except Exception:pass
    finally:
        if child is not None:stop_reader(child)
        result['profile_removed']=root is not None and not root.exists()
    token=payload.get('rpc_token','') if isinstance(payload,dict) else ''
    if isinstance(token,str) and re.fullmatch('[a-f0-9]{32}',token):
        sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result['result']!='PASS' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
