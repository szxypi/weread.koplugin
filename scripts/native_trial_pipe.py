"""Bounded private framing and process supervision; never print payloads."""
import json
import os
import re
import selectors
import signal
import subprocess
import time

MAX_INPUT=8*1024*1024
MAX_FRAME=16384


def write_initial(stream,value):
    raw=json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()
    if not 0<len(raw)<=MAX_INPUT:raise ValueError('trial_pipe/input')
    stream.write(str(len(raw)).encode()+b'\n'+raw);stream.flush()


def read_initial(stream):
    line=stream.readline(12)
    if not re.fullmatch(rb'[1-9][0-9]{0,7}\n',line):raise ValueError('trial_pipe/input')
    length=int(line)
    if length>MAX_INPUT:raise ValueError('trial_pipe/input')
    raw=stream.read(length)
    if len(raw)!=length:raise ValueError('trial_pipe/input')
    value=json.loads(raw)
    if not isinstance(value,dict):raise ValueError('trial_pipe/input')
    return value


def reply(stream,value):
    raw=json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()+b'\n'
    if len(raw)>MAX_FRAME:raise ValueError('trial_pipe/reply')
    stream.write(raw);stream.flush()


class Frames:
    def __init__(self,stream,token,timeout=240):
        if not isinstance(token,str) or not re.fullmatch('[a-f0-9]{32}',token):raise ValueError('trial_pipe/token')
        self.stream=stream;self.prefix=b'WEREAD_NATIVE_THOUGHT_'+token.encode()+b'_'
        self.buffer=b'';self.total=0;self.deadline=time.monotonic()+timeout

    def next(self):
        with selectors.DefaultSelector() as selector:
            selector.register(self.stream,selectors.EVENT_READ)
            while time.monotonic()<self.deadline:
                while b'\n' in self.buffer:
                    line,self.buffer=self.buffer.split(b'\n',1)
                    if not line.startswith(self.prefix):continue
                    if len(line)>MAX_FRAME:raise ValueError('trial_pipe/frame')
                    kind,separator,raw=line[len(self.prefix):].partition(b'=')
                    if not separator or kind not in (b'STEP',b'RESULT'):raise ValueError('trial_pipe/frame')
                    value=json.loads(raw)
                    if not isinstance(value,dict):raise ValueError('trial_pipe/frame')
                    return kind.decode(),value
                if not selector.select(min(1,max(0,self.deadline-time.monotonic()))):continue
                chunk=os.read(self.stream.fileno(),65536)
                if not chunk:raise ValueError('trial_pipe/eof')
                self.total+=len(chunk)
                if self.total>16*1024*1024:raise ValueError('trial_pipe/limit')
                self.buffer+=chunk
                if len(self.buffer)>MAX_FRAME and b'\n' not in self.buffer:raise ValueError('trial_pipe/frame')
        raise TimeoutError('trial_pipe/timeout')


def stop(child):
    # The supervisor owns this isolated session. Descendant groups may differ,
    # so Linux callers use the existing /proc-aware session terminator.
    if child.poll() is None:
        # Let the inner supervisor remove tmpfs and reap its separate native
        # reader session. SIGKILL is only the bounded fallback.
        try:child.terminate();child.wait(timeout=12)
        except (ProcessLookupError,subprocess.TimeoutExpired):pass
    if child.poll() is None:
        if os.name=='posix' and os.path.isdir('/proc'):
            from process_loss_runtime import kill_reader_session
            kill_reader_session(child)
        else:
            try:os.killpg(child.pid,signal.SIGKILL)
            except ProcessLookupError:pass
    child.wait()
    for stream in (child.stdin,child.stdout,child.stderr):
        if stream is not None:stream.close()
