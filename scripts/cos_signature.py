"""Independent small-object COS signing model; no I/O or live credentials."""
import hashlib,hmac,re
from urllib.parse import quote

MAX_BYTES=8*1024*1024


def encode(value):return quote(value,safe='-_.~')


def sign(credential,size,now):
    if not isinstance(credential,dict) or type(size) is not int or not 1<=size<=MAX_BYTES or type(now) is not int or not 1<=now<=4102444800:
        raise ValueError('cos_sign/invalid')
    response=credential.get('Response');data=response.get('Credentials') if isinstance(response,dict) else None
    bucket,path=credential.get('bucket'),credential.get('ObjectName')
    if (not isinstance(bucket,str) or len(bucket)>128 or re.fullmatch(r'[a-z0-9][a-z0-9-]*-[0-9]{1,20}',bucket) is None
            or not isinstance(path,str) or not 1<=len(path.encode())<=2048 or re.search(r'[\x00-\x20\x7f\\?#]',path)
            or not isinstance(data,dict)):
        raise ValueError('cos_sign/invalid')
    path=path[1:] if path.startswith('/') else path
    if not path or path.startswith('/') or path.endswith('/') or any(part in ('','.','..') for part in path.split('/')):
        raise ValueError('cos_sign/invalid')
    path='/'+path;secret_id,secret_key,token=(data.get(k) for k in ('TmpSecretId','TmpSecretKey','Token'))
    if (not isinstance(secret_id,str) or not 1<=len(secret_id)<=4096 or re.fullmatch(r'[A-Za-z0-9_-]+',secret_id) is None
            or any(not isinstance(v,str) or not 1<=len(v)<=limit or not all(33<=ord(c)<=126 for c in v)
                   for v,limit in ((secret_key,4096),(token,8192)))):raise ValueError('cos_sign/invalid')
    expiry=response.get('ExpiredTime')
    if type(expiry) is not int or not now+30<expiry<=now+86400:raise ValueError('cos_sign/invalid')
    host=bucket+'.cos.accelerate.myqcloud.com';key_time=f'{now};{min(now+900,expiry)}'
    headers='content-length='+str(size)+'&host='+encode(host)+'&x-cos-security-token='+encode(token)
    wire='put\n'+path+'\n\n'+headers+'\n'
    key=hmac.new(secret_key.encode(),key_time.encode(),hashlib.sha1).hexdigest()
    text='sha1\n'+key_time+'\n'+hashlib.sha1(wire.encode()).hexdigest()+'\n'
    signature=hmac.new(key.encode(),text.encode(),hashlib.sha1).hexdigest()
    auth=('q-sign-algorithm=sha1&q-ak='+secret_id+'&q-sign-time='+key_time+'&q-key-time='+key_time
          +'&q-header-list=content-length;host;x-cos-security-token&q-url-param-list=&q-signature='+signature)
    url='https://'+host+quote(path,safe='/-_.~')
    return dict(url=url,headers={'Host':host,'Content-Length':str(size),'Authorization':auth,'x-cos-security-token':token})
