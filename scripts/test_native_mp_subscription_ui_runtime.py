#!/usr/bin/env python3
"""Exercise packaged subscription UI against a loopback synthetic service."""
import argparse,secrets,subprocess,threading
from pathlib import Path
from mock_weread import MockServer
from mp_subscription_trial import check,prepare
from native_trial_pipe import Frames,reply,write_initial
from run_native_mp_subscription_ui import validate_stage
from native_mp_subscription_ui_trial import Journal,execute,run
from test_secure_native_session import Backend
from verify_eink_login import BASE

REPO=Path(__file__).resolve().parent.parent
TARGET='MP_WXS_900098';REVIEW=TARGET+'_synthetic'
GRANT=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True);args=parser.parse_args()
    for width,height,dpi in ((600,800,167),(1264,1680,300)):
        for armed in (False,True):
            server=MockServer(0);server.finish_fixture=True
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();token=secrets.token_hex(16)
            plan=prepare(GRANT,server.route('GET',BASE+'/shelf/sync',{})[1],TARGET)
            payload=dict(credentials=GRANT,account_id=TARGET,review_id=REVIEW,shelf_books=plan['count'],members_digest=plan['members_sha256'],
                rpc_token=token,permit_writes=armed,mock_port=server.server_port)
            command=['python3',str(REPO/'scripts/run_native_mp_subscription_ui.py'),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
                '--width',str(width),'--height',str(height),'--dpi',str(dpi),'--mock-port',str(server.server_port)]
            if armed:command.append('--armed')
            child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=180);steps=0
                while True:
                    kind,value=frames.next()
                    if kind=='RESULT':result=value;break
                    assert armed and value=={'seq':steps+1} and steps<2
                    check(plan,GRANT,server.route('GET',BASE+'/shelf/sync',{})[1],steps==0);steps+=1
                    reply(child.stdin,dict(seq=steps,ok=True))
                code=child.wait(timeout=15)
                if code or result.get('result')!='PASS':raise AssertionError('synthetic UI stage: '+repr(result.get('stage')))
                assert result['profile_removed'] and result['installed']['bytes_match'];validate_stage(result['stage'],armed)
                assert steps==(2 if armed else 0);check(plan,GRANT,server.route('GET',BASE+'/shelf/sync',{})[1],False)
                assert server.request_totals[('/shelf/add','')]==server.request_totals[('/shelf/delete','')]==int(armed)
                assert server.request_totals[('/login','native_renewal')]==0
                print(f'PASS: packaged subscription UI {width}x{height}, '+('synthetic roundtrip' if armed else 'zero-write preview'),flush=True)
            finally:
                if child.poll() is None:child.terminate();child.wait(timeout=15)
                server.shutdown();thread.join();server.server_close()
    server=MockServer(0);server.finish_fixture=True
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    class Probe:
        def shelf(self,_credentials):return server.route('GET',BASE+'/shelf/sync',{})[1]
    command=['python3',str(REPO/'scripts/run_native_mp_subscription_ui.py'),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
        '--width','600','--height','800','--dpi','167','--mock-port',str(server.server_port)]
    def runner(plan,credentials,review,armed,on_step):
        return execute(plan,credentials,review,armed,on_step,command,mock_port=server.server_port)
    try:
        journal=Journal(Backend());result=run(Probe(),journal,GRANT,TARGET,REVIEW,lambda _:True,runner,apply=True)
        assert result['result']=='NATIVE_MP_UI_ROUNDTRIP_VERIFIED' and result['independent_steps']==2
        assert result['account_data_posts']==2 and journal.read()[0]['phase']=='restored'
        assert server.request_totals[('/shelf/add','')]==server.request_totals[('/shelf/delete','')]==1
        print('PASS: complete synthetic host-gated subscription trial and permanent intent',flush=True)
    finally:server.shutdown();thread.join();server.server_close()
    server=MockServer(0);server.finish_fixture=True;server.control['shelf_membership_mode']='noack'
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    command[-1]=str(server.server_port)
    try:
        journal=Journal(Backend());result=run(Probe(),journal,GRANT,TARGET,REVIEW,lambda _:True,runner,apply=True)
        assert result['result']=='UNVERIFIED' and result['independent_steps']==0 and journal.read()[0]['phase']=='add_pending'
        assert server.request_totals[('/shelf/add','')]==1 and server.request_totals[('/shelf/delete','')]==0
        assert run(Probe(),journal,GRANT,TARGET,REVIEW,lambda _:True,runner,apply=True)['result']=='UNVERIFIED'
        assert server.request_totals[('/shelf/add','')]==1 and server.request_totals[('/shelf/delete','')]==0
        print('PASS: unknown add receipt stops without removal or replay',flush=True)
    finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
