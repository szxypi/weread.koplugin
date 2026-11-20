#!/usr/bin/env python3
"""Run the real guarded CB task against a synthetic loopback service only."""
import argparse,json,os,re,resource,shutil,signal,subprocess,sys,time
from pathlib import Path

from cb_native_time_bundle_remote_archive import Relay
from native_time_bundle_workspace import restore
from native_time_capture_evidence import validate_evidence
from native_trial_pipe import Frames,read_initial,reply,write_initial
from process_loss_runtime import enable_subreaper
from run_native_thought_trial import read_reply,stop_reader
from run_persistent_ui_probe import extract_candidate


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('koreader','source','candidate'):parser.add_argument('--'+name,required=True,type=Path)
    parser.add_argument('--mock-port',type=int,required=True)
    args=parser.parse_args(argv);runtime=args.koreader.resolve();source=args.source.resolve();candidate=args.candidate.resolve()
    if (sys.platform!='linux' or not 1<=args.mock_port<=65535 or not (runtime/'luajit').is_file() or not candidate.is_file()
            or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        parser.error('isolated Linux KOReader and mock service required')
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupted(_signal,_frame):raise RuntimeError('guarded_cb_mock/interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    payload=root=child=None;outcome='FAILED';workers_reaped=False;token=None;stage='input';event=None
    try:
        payload=read_initial(sys.stdin.buffer)
        if set(payload)!={'bundle','grant','cookies','months','token','armed'} or type(payload['armed']) is not bool:
            raise ValueError('guarded_cb_mock/input')
        token=payload['token'];bundle=payload['bundle'];grant=payload['grant'];plan=bundle['plan']
        if (not isinstance(token,str) or not re.fullmatch('[a-f0-9]{32}',token) or plan['owner']!='900000'
                or plan['book_id']!='CB_SyntheticResume' or grant.get('vid')!='900000'
                or grant.get('accessToken')!='mock-native-access' or grant.get('refreshToken')!='mock-native-refresh'
                or payload['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('guarded_cb_mock/scope')
        validate_evidence(plan,bundle['evidence'],imported=True)
        if int(time.time())<plan['not_before']:raise ValueError('guarded_cb_mock/clock')
        stage='workspace';target=Path('/dev/shm/weread-cb-'+token);os.mkdir(target,0o700);root=target
        profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
        extract_candidate(candidate,plugins);epub,ledger=restore(bundle,root,imported=True);relay=Relay(plan,root,epub)
        private={key:value for key,value in plan.items() if key!='archive_base64'}
        private.update(grant=grant,cookies=payload['cookies'],months=payload['months'],token=token,armed=payload['armed'],mock_port=args.mock_port)
        env=dict(os.environ,KO_HOME=str(profile),TZ='Asia/Shanghai',LD_LIBRARY_PATH=str(runtime/'libs'),SDL_VIDEODRIVER='dummy',
                 EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
        command=[str(runtime/'luajit'),str(source/'spec/koreader/cb_native_time_bundle_guarded_worker.lua'),str(source),str(ledger),str(epub)]
        def emit(kind,value):
            raw=json.dumps(value,separators=(',',':')).encode()
            if len(raw)>3*1024*1024:raise ValueError('guarded_cb_mock/frame')
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_'+kind.encode()+b'='+raw+b'\n');sys.stdout.buffer.flush()
        stage='ready';emit('STEP',dict(kind='ready',source=str(epub)))
        if read_reply(sys.stdin.buffer)!=dict(kind='ready',ok=True):raise ValueError('guarded_cb_mock/denied')
        stage='worker';child=subprocess.Popen(command,cwd=runtime,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
              stderr=None if os.getenv('WEREAD_CB_SYNTHETIC_DEBUG')=='1' else subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,private);frames=Frames(child.stdout,token,timeout=120)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':break
            name=event.get('kind');offered=relay.prepare(event) if name=='claim' else event
            emit('STEP',offered);answer=read_reply(sys.stdin.buffer)
            if set(answer)!={'kind','ok'} or answer['kind']!=name or type(answer['ok']) is not bool:raise ValueError('guarded_cb_mock/reply')
            if name=='claim' and answer['ok']:
                try:relay.recheck()
                except ValueError:answer['ok']=False
            reply(child.stdin,answer)
        if child.wait(timeout=10)!=0 or event.get('result')!='PASS':raise ValueError('guarded_cb_mock/worker')
        if (event.get('attempted') is not True or event.get('forwarded') is not payload['armed']
                or event.get('acknowledged') is not payload['armed']
                or not payload['armed'] and event.get('local_phase')!='claimed'):
            raise ValueError('guarded_cb_mock/result')
        stop_reader(child);child=None;workers_reaped=True
        outcome='ACKNOWLEDGED' if payload['armed'] else 'DRY_BLOCKED'
    except (Exception,KeyboardInterrupt) as error:
        if os.getenv('WEREAD_CB_SYNTHETIC_DEBUG')=='1':
            safe={key:event.get(key) for key in ('result','failed_module','failed_line','task_kind','attempted','acknowledged','forwarded','local_phase')} if isinstance(event,dict) else None
            print(json.dumps({'stage':stage,'error_type':type(error).__name__,'worker':safe}),file=sys.stderr)
    finally:
        if child is not None:
            try:stop_reader(child);workers_reaped=True
            except Exception:workers_reaped=False
        if root is not None:shutil.rmtree(root,ignore_errors=True)
        removed=root is not None and not root.exists()
        if isinstance(token,str) and re.fullmatch('[a-f0-9]{32}',token):
            value=dict(result=outcome,profile_removed=removed,workers_reaped=workers_reaped)
            raw=json.dumps(value,separators=(',',':')).encode()
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+raw+b'\n');sys.stdout.buffer.flush()
    return int(outcome=='FAILED' or not removed or not workers_reaped)


if __name__=='__main__':raise SystemExit(main())
