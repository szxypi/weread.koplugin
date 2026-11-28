#!/usr/bin/env python3
"""Exercise isolated CB reading-time capture with a synthetic loopback server."""
import argparse,json,os,subprocess,threading
from pathlib import Path
from urllib.parse import urlsplit

from mock_weread import CB_READING_ID,MockServer
from native_time_capture import validate
from native_time_capture_evidence import validate_evidence
from test_uploaded_epub_native_reading_runtime import Opener
from verify_cb_reading import CbReadingProbe

REPO=Path(__file__).resolve().parent.parent
FRAME=b'\nWEREAD_NATIVE_TIME_CAPTURE_RESULT='


class VersionedServer(MockServer):
    def route(self,method,target,data):
        status,value=super().route(method,target,data)
        if urlsplit(target).path=='/web/book/chapterInfos' and status==200:
            for row in value['data']:row['book']={'bookId':row['bookId'],'bookVersion':7}
        return status,value


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    args=parser.parse_args();server=VersionedServer(0);server.cb_reading=True
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        probe=CbReadingProbe();probe.opener=Opener(server);probe.vid='900000'
        probe.set_cookie('wr_vid','900000');probe.set_cookie('wr_skey','mock_key');probe.authenticated=True
        sample=probe.prepare(1,expected_book_id=CB_READING_ID)[0]
        payload={key:sample[key] for key in ('book_id','chapter_uid','source_format','source_text','source_raw_sha256',
                                               'source_sample_offset','shelf_ids','shelf_books')}
        payload.update(cb_reading=True,vid='900000',cookies={'wr_vid':'900000','wr_skey':'mock_key'},cb_mock_port=server.server_port,
                       native_time_capture={'device_sha256':'a'*64,'baseline_sha256':'b'*64,'book_version':7})
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            env=os.environ|dict(SDL_VIDEODRIVER='dummy');env.pop('LD_LIBRARY_PATH',None)
            cmd=['python3',str(REPO/'scripts/run_native_time_capture.py'),'--koreader',str(args.koreader),
                 '--candidate',str(args.candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi),
                 '--cb-reading','--cb-mock-port',str(server.server_port),'--sqlite-evidence']
            child=subprocess.run(cmd,input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env,timeout=240)
            if child.stdout.count(FRAME)!=1 or len(child.stdout)>10*1024*1024:raise ValueError('synthetic_capture/frame')
            value=json.loads(child.stdout.split(FRAME,1)[1])
            if child.returncode or value.get('result')!='PASS' or value.get('profile_removed') is not True:
                diagnostic={key:value.get(key) for key in ('failure_type','failure_reason','diagnostic','capture_failed_line')}
                raise ValueError('synthetic_capture/runner '+repr(diagnostic))
            plan=validate(value['capture'],imported=True);validate_evidence(plan,value['sqlite_evidence'],imported=True)
            assert plan['book_id']==CB_READING_ID and plan['seconds']>=5 and plan['not_before']>plan['ended_at']
            assert value['account_data_posts']==0 and value['authentication_posts']==0
            print(f'PASS: native CB offline time capture {width}x{height}',flush=True)
        assert server.request_totals[('/web/book/read','')]==0 and server.request_totals[('/web/login/renewal','')]==0
    finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
