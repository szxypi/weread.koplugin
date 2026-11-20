#!/usr/bin/env python3
"""Synthetic-only ReaderUI trial with a private archive and RPC relay."""
import argparse,json,os,re,resource,shutil,signal,subprocess,sys
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
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);runtime=args.koreader.resolve();source=args.source.resolve();candidate=args.candidate.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not candidate.is_file()
            or not all(1<=item<=4096 for item in (args.width,args.height,args.dpi))
            or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        parser.error('isolated Linux KOReader runtime required')
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupted(_signal,_frame):raise RuntimeError('independent_ui_synthetic/interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    payload=root=child=None;outcome='FAILED';workers_reaped=False;token=None;pending=None
    try:
        payload=read_initial(sys.stdin.buffer)
        if set(payload)!={'bundle','grant','cookies','months','token','armed'} or type(payload['armed']) is not bool:
            raise ValueError('independent_ui_synthetic/input')
        token=payload['token'];bundle=payload['bundle'];grant=payload['grant'];plan=bundle['plan']
        if (not isinstance(token,str) or not re.fullmatch('[a-f0-9]{32}',token)
                or plan['owner']!='900000' or plan['book_id']!='900001' or grant.get('vid')!='900000'
                or grant.get('accessToken')!='mock-native-access' or grant.get('refreshToken')!='mock-native-refresh'
                or payload['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('independent_ui_synthetic/scope')
        validate_evidence(plan,bundle['evidence'])
        target=Path('/dev/shm/weread-native-time-'+token);os.mkdir(target,0o700);root=target
        profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
        extract_candidate(candidate,plugins);epub,ledger=restore(bundle,root)
        html=root/'synthetic.html';html.write_text('<html><body>'+'<p>Synthetic text for native UI.</p>'*120+'</body></html>')
        relay=Relay(plan,root,epub);mode='success' if payload['armed'] else 'dry_run'
        private={key:value for key,value in plan.items() if key!='archive_base64'}
        private.update(grant=grant,guest='synthetic-guest',config='synthetic-config',mode=mode,token=token,months=payload['months'])
        env=dict(os.environ,KO_HOME=str(profile),TZ='Asia/Shanghai',LD_LIBRARY_PATH=str(runtime/'libs'),
                 EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                 EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
        command=[str(runtime/'luajit'),str(source/'spec/koreader/native_time_bundle_ui_rpc.lua'),str(source),str(html),str(ledger),str(epub)]
        def emit(kind,value):
            raw=json.dumps(value,separators=(',',':')).encode()
            if len(raw)>3*1024*1024:raise ValueError('independent_ui_synthetic/frame')
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_'+kind.encode()+b'='+raw+b'\n');sys.stdout.buffer.flush()
        emit('STEP',dict(kind='ready',source=str(epub)))
        if read_reply(sys.stdin.buffer)!=dict(kind='ready',ok=True):raise ValueError('independent_ui_synthetic/denied')
        child=subprocess.Popen(command,cwd=runtime,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,private);frames=Frames(child.stdout,token,timeout=120)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':break
            name=event.get('kind');pending=name
            if name not in ('selection','claim','ack') or not payload['armed'] and name=='ack':raise ValueError('independent_ui_synthetic/order')
            offered=relay.prepare(event) if name=='claim' else event
            emit('STEP',offered);answer=read_reply(sys.stdin.buffer)
            if set(answer)!={'kind','ok'} or answer['kind']!=name or type(answer['ok']) is not bool:
                raise ValueError('independent_ui_synthetic/reply')
            if name=='claim' and not payload['armed'] and answer['ok']:
                reply(child.stdin,dict(kind='claim',ok=False));pending=None;raise ValueError('independent_ui_synthetic/dry_approval')
            if name=='claim' and answer['ok']:
                try:relay.recheck()
                except ValueError:answer['ok']=False
            reply(child.stdin,answer);pending=None
        if child.wait(timeout=10)!=0 or event.get('result')!='PASS' or event.get('mode')!=mode:
            raise ValueError('independent_ui_synthetic/child')
        if (event.get('native_menu') is not True or event.get('dialog_correct') is not True or event.get('workers_reaped') is not True
                or event.get('background_service') is not True or event.get('local_phase')!=('none' if payload['armed'] else 'claimed')):
            raise ValueError('independent_ui_synthetic/result')
        stop_reader(child);child=None;workers_reaped=True
        outcome='ACKNOWLEDGED' if payload['armed'] else 'DRY_BLOCKED'
    except (Exception,KeyboardInterrupt):
        if child is not None and child.poll() is None and pending:
            try:reply(child.stdin,dict(kind=pending,ok=False))
            except Exception:pass
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
