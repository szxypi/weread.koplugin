#!/usr/bin/env python3
"""Exercise the duplex native-chapter time runner against loopback only."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading
import time

from native_trial_pipe import Frames, reply, stop, write_initial
from native_direct_time_trial_contract import validate_claim,validate_selection
from test_native_direct_home_owner_runtime import StoreHandler
import test_native_direct_position_runtime as fixture
from test_native_direct_position_runtime import BODY, REPO
from verify_native_statistics import period
from verify_native_time_capture import full_point
from shelf_flag_change_contract import state_hash


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--ko2',action='store_true');parser.add_argument('--automatic',action='store_true')
    parser.add_argument('--full-interval',action='store_true');args=parser.parse_args()
    if args.full_interval and not args.automatic:parser.error('full interval requires automatic mode')
    server=ThreadingHTTPServer(('127.0.0.1',0),StoreHandler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='direct-time-trial-test-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            cases=((False,True,False),) if args.full_interval else ((False,True,False),(True,True,False),(True,True,True),(True,False,False))
            for armed,ack,add_zero in cases:
                server.time_preflight=True;server.no_position=False;server.live_time=True;server.time_delta=0;server.time_ack=ack
                server.time_add_zero=add_zero
                server.mode='preview';server.calls=[];server.leaked=False;server.valid=True;server.review=None
                fixture.BODY=BODY
                token=secrets.token_hex(16)
                raw_point=dict(bookId='42',chapterUid=37,chapterIdx=1,chapterOffset=1,progress=50,summary='Synthetic point')
                point=full_point(raw_point,'42','native');month=period('monthly',int(time.time()))[0]
                baseline=dict(native_point=point,web_point=point,counts=dict(readingTime=100,recordReadingTime=0,ttsTime=0),
                    shelf_hash=state_hash(dict(books=[dict(bookId='42',finishReading=0,secret=0)],archive=[])),
                    months={str(month):dict(baseTime=month,readTimes={},totalReadTime=0,readDays=0)},
                    guest='5ecdcfd7f',config_token='synthetic-config')
                expected=dict(book_id='42',uid='37',version=1,source_sha256=hashlib.sha256(BODY.encode()).hexdigest())
                payload=dict(token=token,armed=armed,credentials=dict(vid='12345678',accessToken='synthetic-access',
                    refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19),
                    web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},book_id='42',uid='37',book_version=1,
                    source_sha256=expected['source_sha256'],months=[month],
                    mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                if args.automatic:payload['automatic']=True
                if args.full_interval:payload['full_interval']=True
                width,height,dpi=('1264','1680','300') if args.ko2 else ('600','800','167')
                command=[sys.executable,str(REPO/'scripts/run_native_direct_time_trial.py'),'--koreader',str(args.koreader),
                    '--candidate',str(candidate),'--width',width,'--height',height,'--dpi',dpi]
                if armed:command.append('--armed')
                if args.automatic:command.append('--automatic')
                if args.full_interval:command.append('--full-interval')
                child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
                events=[];result=None;seconds=None
                try:
                    write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=540 if args.full_interval else 360,max_frame=65536)
                    while True:
                        kind,event=frames.next()
                        if kind=='RESULT':result=event;break
                        name=event['kind'];events.append(name);ok=True
                        if name=='ready':
                            seconds=event['seconds'];assert 5<=seconds<=20
                            ready_at=time.monotonic()
                        elif name=='selection':
                            selection=event['selection'];ref=event['reference']
                            assert selection['book_id']=='42' and selection['current_day'] and selection['native_direct']
                            assert selection['seconds']==seconds and ref['chapter_uid']=='37'
                            validation_now=None
                            if args.full_interval:
                                assert 299<=time.monotonic()-ready_at<=420,'default timer did not wait five minutes'
                                validation_now=max(row['start_time']+row['duration'] for row in selection['protocol_rows'])
                                assert 299<=time.time()-validation_now<=420,'selected interval age unexpected'
                            validate_selection(selection,ref,expected,seconds,now=validation_now)
                        elif name=='claim':
                            assert event['record']['phase']=='claimed' and event['body']['books'][0]['readingTime']==seconds
                            validate_claim(event,selection,ref,expected,baseline,payload['credentials'])
                            ok=armed
                        elif name=='ack':
                            ok=event['status']==200 and event['response'].get('succ')==1
                        else:raise AssertionError('unexpected step')
                        reply(child.stdin,dict(kind=name,ok=ok))
                    child.wait(timeout=15)
                    if not armed:
                        assert result['result']=='DRY_BLOCKED' and events==['ready','selection','claim'],result
                        assert server.time_delta==0
                    elif ack:
                        assert result['result']=='ACKNOWLEDGED' and events==['ready','selection','claim','ack'],result
                        assert server.time_delta==seconds
                    else:
                        assert result['result']=='UNVERIFIED' and events==['ready','selection','claim','ack'],result
                        assert server.time_delta==0
                    assert result['profile_removed'] and server.valid and not server.leaked
                    assert sum(path=='/book/batchUploadProgress' for _,_,path in server.calls)==int(armed)
                finally:stop(child)
        if args.full_interval:
            print('PASS: default five-minute automatic timer and denied dispatch on loopback')
        else:
            print('PASS: supervised native chapter time dry, success, new zero bucket, and missing receipt on loopback')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
