"""Read the current reader signing token; no fixed-token fallback or storage."""
from verify_web_source_progress import BASE

URL=BASE+'/web/getConfig'


def token(value):
    result=value.get('token') if isinstance(value,dict) else None
    if not isinstance(result,str) or not 1<=len(result)<=4096 or any(ord(c)<33 or ord(c)>126 for c in result):raise ValueError('web_config/token')
    return result
