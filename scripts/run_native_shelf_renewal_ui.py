#!/usr/bin/env python3
"""Private tmpfs runner; the host independently permits every renewal step."""
import argparse,json,os,re,resource,signal,subprocess,sys,tempfile
from pathlib import Path
from native_trial_pipe import Frames,read_initial,reply,stop,write_initial
from run_native_direct_position_owner import synthetic_endpoint_allowed
from run_persistent_ui_probe import extract_candidate
from verify_eink_renewal import validate_credentials
from verify_owner_reading import validate_cookies

REPO=Path(__file__).resolve().parent.parent


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True);parser.add_argument('--armed',action='store_true')
    parser.add_argument('--width',type=int,default=1264);parser.add_argument('--height',type=int,default=1680);parser.add_argument('--dpi',type=int,default=300)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not args.candidate.is_file()
            or not all(1<=x<=4096 for x in (args.width,args.height,args.dpi))
            or not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines())):
        parser.error('isolated Linux runtime and tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupted(_sig,_frame):raise RuntimeError('shelf_renewal/interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    payload=root=child=token=None;stage='input';result='UNVERIFIED';clean=False;diagnostic=None;fresh=None
    try:
        payload=read_initial(sys.stdin.buffer);token=payload.get('token')
        if (not isinstance(token,str) or not re.fullmatch('[a-f0-9]{32}',token)
                or type(payload.get('armed')) is not bool or payload['armed'] is not args.armed
                or not synthetic_endpoint_allowed(payload,payload.get('mock_endpoint'))):raise ValueError('input')
        grant=payload['credentials'];validate_credentials(grant);validate_cookies(payload['web_cookies'],grant['vid'])
        if type(payload.get('expected_count')) is not int or not 1<=payload['expected_count']<=5000:raise ValueError('count')
        with tempfile.TemporaryDirectory(prefix='weread-shelf-renewal-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
            xdg=root/'xdg';xdg.mkdir(mode=0o700);extract_candidate(args.candidate,plugins);plugin=plugins/'weread.koplugin'
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            private=dict(token=token,armed=args.armed,credentials=grant,cookies=payload['web_cookies'],expected_count=payload['expected_count'])
            if payload.get('mock_endpoint') is not None:private['mock_endpoint']=payload['mock_endpoint']
            stage='ui';child=subprocess.Popen([str(runtime/'luajit'),str(REPO/'spec/koreader/native_shelf_renewal_ui.lua'),str(REPO)],
                cwd=runtime,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            write_initial(child.stdin,private);frames=Frames(child.stdout,token,timeout=360,max_frame=2*1024*1024)
            expected=['expiry','claim','verified','shelf'] if args.armed else ['expiry','claim'];seen=[];reported=None
            while True:
                kind,event=frames.next()
                if kind=='RESULT':reported=event;break
                name=event.get('kind')
                if len(seen)>=len(expected) or name!=expected[len(seen)]:raise ValueError('order')
                seen.append(name)
                if name=='verified':fresh=event.get('credentials');validate_credentials(fresh)
                sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(event,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
                answer=json.loads(sys.stdin.buffer.readline(65537))
                if set(answer)!={'kind','ok'} or answer['kind']!=name or type(answer['ok']) is not bool:raise ValueError('reply')
                if name=='claim' and not args.armed and answer['ok']:raise ValueError('dry_grant')
                reply(child.stdin,answer)
            if payload.get('mock_endpoint') and isinstance(reported,dict):
                diagnostic={key:reported[key] for key in ('result','failed_module','failed_line','synthetic_error') if key in reported};diagnostic['events']=seen
            expected_result={'result':'PASS','native_ui':True,'one_renewal':True,'shelf_rendered':True,'workers_reaped':True}
            if args.armed:
                if child.wait(timeout=15)!=0 or reported!=expected_result or seen!=expected:raise ValueError('ui')
                result='SHELF_RENEWAL_VERIFIED'
            else:
                # Denial aborts before any HTTP authorization; the inner process may fail.
                child.wait(timeout=15)
                if seen!=expected:raise ValueError('ui')
                result='DRY_BLOCKED'
            stop(child);child=None;stage='audit'
            allowed=[item for item in profile.rglob('native-authorization.lua') if item.is_file() and plugin not in item.parents]
            if len(allowed)!=1 or allowed[0].is_symlink():raise ValueError('native_store')
            secrets=[grant[key].encode() for key in ('accessToken','refreshToken','deviceId')]
            if fresh:secrets.extend(fresh[key].encode() for key in ('accessToken','refreshToken','deviceId'))
            secrets.extend(value.encode() for key,value in payload['web_cookies'].items() if key!='wr_vid' and len(value)>=8)
            for item in profile.rglob('*'):
                if item.is_symlink():raise ValueError('symlink')
                if item.is_file() and plugin not in item.parents:
                    if item.stat().st_size>128*1024*1024:raise ValueError('size')
                    if item!=allowed[0] and any(secret in item.read_bytes() for secret in secrets):raise ValueError('credential_file')
            from run_owner_reading_probe import check_installed
            if check_installed(args.candidate,profile).get('bytes_match') is not True:raise ValueError('installed')
            diagnostic=None
        clean=not root.exists()
    except (Exception,KeyboardInterrupt):result='UNVERIFIED'
    finally:
        if child is not None:stop(child)
        if root is not None and not root.exists():clean=True
        if isinstance(token,str) and re.fullmatch('[a-f0-9]{32}',token):
            value=dict(result=result,profile_removed=clean,stage=stage)
            if diagnostic is not None:value['diagnostic']=diagnostic
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(value).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result not in ('SHELF_RENEWAL_VERIFIED','DRY_BLOCKED') or not clean)


if __name__=='__main__':raise SystemExit(main())
