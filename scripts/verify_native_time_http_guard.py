#!/usr/bin/env python3
"""Synthetic loopback HTTP exercise; offline until explicitly requested."""
import argparse
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json
import socket
import subprocess
import threading


def scenario(command,mode):
    calls=[]
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*_args):pass
        def respond(self,method):
            size=int(self.headers.get('Content-Length','0'))
            if size>65536:raise ValueError('synthetic_http/body')
            if size:self.rfile.read(size)
            calls.append((method,self.path))
            if self.path=='/native/write' and mode=='disconnect':
                self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
            status=201 if self.path=='/native/write' and mode=='bad_status' else 302 if self.path=='/native/write' and mode=='redirect' else 200
            body=json.dumps({} if self.path=='/native/write' and mode=='no_ack' else {'succ':1}).encode()
            self.send_response(status);self.send_header('Content-Length',str(len(body)))
            if status==302:self.send_header('Location','/redirect-target')
            self.end_headers();self.wfile.write(body)
        def do_GET(self):self.respond('GET')
        def do_POST(self):self.respond('POST')
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        child=subprocess.run(command,input=json.dumps({'port':server.server_port,'mode':mode}).encode(),
                             stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30)
        frame=b'\nWEREAD_SYNTHETIC_HTTP='
        if child.returncode or len(child.stdout)>65536 or child.stdout.count(frame)!=1:raise ValueError('synthetic_http/child')
        value=json.loads(child.stdout.split(frame)[1])
        expected={'result':'PASS','mode':mode,'attempted':True,'forwarded':mode!='dry_run',
                  'acknowledged':mode=='success','replay_blocked':True}
        if value!=expected or calls!=[('GET','/native/read'),('POST','/web/read')]+([] if mode=='dry_run' else [('POST','/native/write')]):
            raise ValueError('synthetic_http/mismatch')
    finally:
        server.shutdown();server.server_close();thread.join(timeout=5)
        if thread.is_alive():raise ValueError('synthetic_http/cleanup')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    report={'result':'OFFLINE_ONLY','synthetic_only':True,'account_data_posts':0,'authentication_posts':0}
    mode='setup'
    try:
        if args.lua_command:
            for mode in ('success','dry_run','bad_status','no_ack','disconnect','redirect'):scenario(args.lua_command,mode)
            report.update(result='SYNTHETIC_LOOPBACK_HTTP_VERIFIED',scenarios=6,read_only_web_post=True,
                          dry_run_sent_no_write=True,invalid_http_receipts_blocked=True,disconnect_never_replayed=True,redirect_blocked=True)
    except Exception as error:
        report.update(result='UNVERIFIED',synthetic_failure_mode=mode,synthetic_failure_type=type(error).__name__)
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
