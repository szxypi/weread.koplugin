"""Private-pipe comparison only; caller supplies grants and read-only reference."""
import json
import subprocess
from verify_native_position_lua import equivalent

FRAME=b'\nWEREAD_NATIVE_POSITION_REVIEW='


def compare(credentials,metadata,observation,command,runner=subprocess.run):
    raw=json.dumps(dict(credentials=credentials,metadata=metadata),ensure_ascii=False).encode()
    if len(raw)>65536:raise ValueError('position_review/input_limit')
    child=runner(command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=90)
    if child.returncode or not isinstance(child.stdout,bytes) or len(child.stdout)>65536 or child.stdout.count(FRAME)!=1:
        raise ValueError('position_review/child')
    try:value=json.loads(child.stdout.split(FRAME)[1])
    except Exception:raise ValueError('position_review/frame') from None
    expected=dict(result='PASS',native_gets=6,readbacks=2,observation=observation,unchanged=True)
    if not equivalent(expected,value):raise ValueError('position_review/mismatch')
