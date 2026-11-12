"""Native time-only report prototype; no transport or account side effects.

Copyright (C) 2026 MiuRead contributors. Adapted to Python from
miuread/readtime_protocol.lua at c1893562aa25a870b8dd076d7be062a3348f823e
(AGPL-3.0-only). Byte substitution and rotation reference AnkioTomas/moon
43b2181da6eb5285b62114da85e1413d2f8464e4/book.koplugin/source/wechat/app.lua
(GPL-3.0). This derivative is distributed under the repository's AGPL-3.0.
Full attribution/license texts: integrations/licenses/readtime-sources.txt.
Endpoint catalog: teng-lin/weread-omni 88bd2e095d7d7ee423eaadf8f40653e72c5be6d4.
"""
import hashlib
import re
import time
from verify_eink_renewal import validate_credentials

DEFAULT_GUEST_TOKEN='5ecdcfd7f'  # Public client constant; not account authentication.
REMAP=bytes([
52,202,85,64,29,182,147,198,49,48,41,53,50,167,184,17,
    194,181,22,250,139,177,36,164,16,144,4,233,8,248,59,138,
    156,140,68,249,188,92,105,226,161,218,210,211,117,137,247,30,
    45,80,86,215,114,83,191,34,251,32,15,1,46,69,135,110,
    102,72,242,224,205,254,103,169,67,244,148,81,206,165,74,238,
    19,38,142,204,170,51,20,93,14,57,187,207,145,43,129,77,
    234,153,236,26,44,133,197,217,54,116,75,24,225,241,61,157,
    65,159,180,23,13,214,76,190,220,175,151,40,119,240,98,255,
    113,193,200,39,143,108,104,168,155,230,89,28,27,18,9,152,
    78,63,6,55,0,186,31,10,25,47,201,213,208,87,73,111,
    253,37,228,97,12,66,203,150,100,95,219,173,96,35,141,154,
    109,195,196,94,62,185,146,106,189,91,7,127,118,149,237,79,
    171,132,122,128,231,120,199,229,235,115,131,107,252,56,70,125,
    71,101,179,82,99,58,5,209,239,163,166,222,158,60,2,174,
    178,123,160,246,243,42,192,172,134,3,90,84,11,245,130,212,
    126,227,223,176,216,221,33,232,124,136,162,121,88,112,183,21,
])


def integer(value,low,high):return type(value) is int and low<=value<=high


def guest_token(feature):
    if not isinstance(feature,dict) or not isinstance(feature.get('feature'),dict):raise ValueError('readtime/feature')
    value=feature['feature'].get('guest_token')
    if value is None or value=='':return DEFAULT_GUEST_TOKEN,'client_default'
    if not isinstance(value,str) or not 1<=len(value.encode())<=4096:raise ValueError('readtime/guest')
    return value,'remote'


def rotate(value):
    checksum=0
    for byte in value:checksum^=byte
    offset=(checksum%11)%len(value)
    return value[-offset:]+value[:-offset] if offset else value


def sign(parts):
    if not isinstance(parts,(tuple,list)) or not 1<=len(parts)<=64 or any(not isinstance(p,str) or len(p.encode())>32768 for p in parts):raise ValueError('readtime/sign')
    joined=b''.join(sorted([b'5a6f1']+[bytes(REMAP[b] for b in part.encode()) for part in parts]))
    first=hashlib.sha256(rotate(joined)).hexdigest().encode()
    return hashlib.sha256(rotate(first)).hexdigest()


def zone(value):
    if not isinstance(value,str) or not re.fullmatch(r'[+-](?:0[0-9]|1[0-4]):[0-5][0-9]',value) or value[1:3]=='14' and value[4:]!='00':raise ValueError('readtime/zone')
    return value


def local_zone():
    # Native getRawOffset excludes daylight saving time.
    minutes=-time.timezone//60
    return zone(('-' if minutes<0 else '+')+f'{abs(minutes)//60:02}:{abs(minutes)%60:02}')


def validate_rows(rows,book_id,now):
    if not isinstance(book_id,str) or not re.fullmatch(r'[1-9][0-9]{0,19}',book_id) or not integer(now,1,4102444800):raise ValueError('readtime/identity_clock')
    if not isinstance(rows,list) or not 1<=len(rows)<=100:raise ValueError('readtime/rows')
    group=None;previous=0;total=0
    if any(not isinstance(r,dict) or not integer(r.get('start_time'),1,4102444800) for r in rows):raise ValueError('readtime/rows')
    for row in sorted(rows,key=lambda r:r['start_time']):
        if (not isinstance(row,dict) or set(row)!={'start_time','duration','time_zone','book_version'}
                or not integer(row['start_time'],1,4102444800) or not integer(row['duration'],1,60)
                or row['start_time']<previous or row['start_time']+row['duration']>now
                or not integer(row['book_version'],1,2147483647)):raise ValueError('readtime/rows')
        zone(row['time_zone']);current=row['book_version']
        if group is not None and current!=group:raise ValueError('readtime/mixed_source')
        group=current;previous=row['start_time']+row['duration'];total+=row['duration']
    if total>600:raise ValueError('readtime/batch_limit')
    return total


def hours(rows):
    buckets={}
    for row in rows:
        at=row['start_time'];left=row['duration'];tz=zone(row['time_zone'])
        while left:
            hour=at-at%3600;seconds=min(left,hour+3600-at);key=(hour,tz)
            bucket=buckets.setdefault(key,dict(startOfHour=hour,timeZone=tz,readingTime=0,ttsTime=0))
            bucket['readingTime']+=seconds
            if bucket['readingTime']>3600:raise ValueError('readtime/hour_limit')
            at+=seconds;left-=seconds
    return [buckets[key] for key in sorted(buckets)]


def batch(credentials,book_id,rows,guest,config_token,now,random,outer_timestamp,outer_random,*,current_zone):
    validate_credentials(credentials);total=validate_rows(rows,book_id,now);tz=zone(current_zone)
    if (not integer(random,0,999) or not integer(outer_random,0,999) or not integer(outer_timestamp,1000,4102444800999)
            or not 0<=outer_timestamp-now*1000<2000 or any(not isinstance(t,str) or not 1<=len(t.encode())<=4096 for t in (guest,config_token))):raise ValueError('readtime/parameters')
    buckets=hours(rows)
    body=dict(bookId=book_id,bookVersion=rows[0]['book_version'],appId='',deviceId=credentials['deviceId'],installId='',summary='',
        progress=0,currentProgress=0,autoTime=0,isLecture=0,isResendReadingInfo=1,lectureTime=0,lectureTextTime=0,novalTime=0,ttsTime=0,
        finish=False,risk=0,readingTime=total,recordCreateTimeZone=tz,timestamp=now,random=random,hours=buckets)
    parts=[credentials['vid'],body['deviceId'],'',book_id,'0',tz,str(total),'0']
    parts.extend('_'.join(str(b[k]) for k in ('startOfHour','timeZone','readingTime','ttsTime')) for b in buckets)
    body['signature']=sign([guest,str(random),str(now),'_'.join(parts)])
    return dict(books=[body],timestamp=outer_timestamp,random=outer_random,
        signature=hashlib.sha256((str(outer_timestamp)+config_token+str(outer_random)).encode()).hexdigest())


def confirmed(value):
    return isinstance(value,dict) and not any(k in value and not (value[k] is None or type(value[k]) is int and value[k]==0) for k in ('errcode','errCode')) and (value.get('succ') is True or type(value.get('succ')) is int and value['succ']==1)
