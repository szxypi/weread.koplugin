#!/usr/bin/env python3
"""Run native packaged upload UI scope checks using a synthetic loopback service."""
import argparse,base64,os,secrets,subprocess,threading
from pathlib import Path
from mock_weread import MockServer
from native_trial_pipe import Frames,write_initial
from run_native_personal_upload_ui import validate_stage
from synthetic_upload_epub import build

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    kind=parser.add_mutually_exclusive_group();kind.add_argument('--epub',action='store_true');kind.add_argument('--large-epub',action='store_true');kind.add_argument('--fixture-format',choices=('pdf','mobi','azw3'))
    args=parser.parse_args()
    for width,height,dpi in ((600,800,167),(1264,1680,300)):
        for armed in (False,True):
            server=MockServer(0);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            token=secrets.token_hex(16)
            payload=dict(credentials=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',
                deviceId='eink334691225'+'1'*19),name='SyntheticUpload.'+args.fixture_format if args.fixture_format else 'SyntheticLargeEpub.epub' if args.large_epub else 'SyntheticUploadEpub.epub' if args.epub else 'SyntheticUpload.txt',
                shelf_books=26,rpc_token=token,permit_writes=armed,mock_port=server.server_port)
            if args.epub:payload.update(fixture='epub',body_base64=base64.b64encode(build()).decode('ascii'))
            elif args.large_epub:payload['fixture']='large_epub'
            elif args.fixture_format:
                from synthetic_pdf_trial import build as build_pdf
                from synthetic_format_trial import build as build_format
                body=build_pdf() if args.fixture_format=='pdf' else build_format(args.fixture_format)
                payload.update(fixture=args.fixture_format,body_base64=base64.b64encode(body).decode('ascii'))
            command=['python3',str(REPO/'scripts/run_native_personal_upload_ui.py'),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
                '--width',str(width),'--height',str(height),'--dpi',str(dpi),'--mock-port',str(server.server_port)]
            if armed:command.append('--armed')
            child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=os.environ.copy())
            try:
                write_initial(child.stdin,payload);kind,result=Frames(child.stdout,token,timeout=150).next()
                code=child.wait(timeout=15)
                if code or kind!='RESULT' or result.get('result')!='PASS':raise AssertionError('synthetic UI stage: '+repr(result.get('stage')))
                assert result['profile_removed'] and result['installed']['bytes_match'];stage=validate_stage(result['stage'],armed)
                if armed:assert stage['target']==('CB_upload'+args.fixture_format if args.fixture_format else 'CB_uploadLargeEpub' if args.large_epub else 'CB_uploadEpub' if args.epub else 'CB_uploadtest')
                assert server.request_totals[('/cos/getcredential','')]==int(armed)
                assert server.request_totals[('/synthetic/object','')]==int(armed)
                assert server.request_totals[('/cos/notify','')]==int(armed)
                assert server.request_totals[('/login','native_renewal')]==0
                print(f'PASS: packaged {args.fixture_format or ("large EPUB" if args.large_epub else "EPUB" if args.epub else "TXT")} upload UI {width}x{height}, '+('synthetic upload' if armed else 'cancel-only preview'),flush=True)
            finally:
                if child.poll() is None:child.terminate();child.wait(timeout=15)
                server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
