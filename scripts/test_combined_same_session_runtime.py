#!/usr/bin/env python3
"""Use one live KOReader session for synthetic upload and reading."""
import argparse,base64,json,os,secrets,subprocess,threading
from pathlib import Path
from mock_weread import CB_READING_ID,MockServer
from native_trial_pipe import Frames,reply,write_initial
from synthetic_upload_epub import TEXT,build_reading
from test_uploaded_epub_native_reading_runtime import Opener
from verify_cb_reading import CbReadingProbe

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True);parser.add_argument('--deny-gate',action='store_true');args=parser.parse_args()
    for width,height,dpi in (((600,800,167),) if args.deny_gate else ((600,800,167),(1264,1680,300))):
        server=MockServer(0);server.combined_upload_read=True
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        token=secrets.token_hex(16)
        grant=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)
        payload=dict(credentials=grant,name='SyntheticUploadEpub.epub',shelf_books=26,rpc_token=token,permit_writes=True,
            fixture='reading_epub',body_base64=base64.b64encode(build_reading()).decode('ascii'),mock_port=server.server_port,same_session=True)
        command=['python3',str(REPO/'scripts/run_combined_same_session.py'),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
            '--width',str(width),'--height',str(height),'--dpi',str(dpi),'--mock-port',str(server.server_port)]
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=os.environ.copy())
        try:
            write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=240);kind,step=frames.next()
            assert kind=='STEP' and step==dict(seq=1,target=CB_READING_ID) and CB_READING_ID in server.shelf_added
            if args.deny_gate:
                reply(child.stdin,dict(seq=1,ok=False,payload={}))
                kind,result=frames.next();assert child.wait(timeout=15)!=0 and kind=='RESULT'
                assert result['error']=='combined/gate' and result['profile_removed'] and not result['stages']
                assert server.request_totals[('/web/book/chapterInfos','')]==0 and server.request_totals[('/web/book/read','')]==0
                print('PASS: refused gate prevents all synthetic reading requests',flush=True)
                continue
            probe=CbReadingProbe();probe.opener=Opener(server);probe.vid='900000';probe.set_cookie('wr_vid','900000');probe.set_cookie('wr_skey','mock_key');probe.authenticated=True
            sample=probe.prepare(1,expected_book_id=CB_READING_ID)[0]
            assert TEXT in sample['source']
            reading={key:sample[key] for key in ('book_id','chapter_uid','source_format','source_text','source_raw_sha256','source_sample_offset','shelf_ids','shelf_books')}
            reading.update(cb_reading=True,vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key'),
                cb_mock_port=server.server_port,combined_upload_read=True)
            reply(child.stdin,dict(seq=1,ok=True,payload=reading))
            kind,result=frames.next();code=child.wait(timeout=15)
            if code or kind!='RESULT' or result.get('result')!='PASS':raise AssertionError('combined stage: '+repr(result))
            assert result['profile_removed'] and result['installed']['bytes_match'] and not result['stages']
            assert all(result['upload'][key] is True for key in ('continuous_reading','read_text_visible','read_page_turn','source_bytes_bound'))
            for route in ('/cos/getcredential','/synthetic/object','/cos/notify'):assert server.request_totals[(route,'')]==1
            assert server.request_totals[('/web/book/read','')]==0 and server.request_totals[('/login','native_renewal')]==0
            print(f'PASS: same-session synthetic upload and native reading {width}x{height}',flush=True)
        finally:
            if child.poll() is None:child.terminate();child.wait(timeout=15)
            server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
