"""Read-only cross-chapter verification for one supervised new bookmark.

The caller owns creation, deletion and durable receipts. This module only reads
the selected sources and the single independently identified record. Private
data and credentials stay in process memory and anonymous pipes.
"""
import hashlib
import json
import subprocess
from urllib.parse import urlencode

from bookmark_point import from_mark,project
from native_chapter_package import password,read
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_translation_preflight import catalog,catalog_body

FRAME=b'\nWEREAD_DIRECT_PERSONAL_OWNER_RUN='
SIZES=((600,800,167),(1264,1680,300))


def prepare_origin(credentials,source,*,probe=None):
    book,uid=source['book_id'],source['uid']
    if hashlib.sha256(source['source']).hexdigest()!=source['source_sha256']:
        raise ValueError('cross_bookmark/source')
    native=probe or ChapterProbe();native.allowed={book}
    info=native.request('book',BASE+'/book/info?'+urlencode(dict(bookId=book)),credentials=credentials)
    model=catalog(native.request('catalog',BASE+'/book/chapterInfos',catalog_body(book),credentials=credentials),book,info)
    target=[row for row in model['chapters'] if str(row['uid'])==uid]
    origin=next((row for row in model['chapters'] if str(row['uid'])!=uid and row.get('free_or_owned') is True
        and row.get('wordCount',0)>0),None)
    if (model['format']!='epub' or model['version']!=source['book_version'] or len(target)!=1
            or target[0].get('free_or_owned') is not True or not origin):raise ValueError('cross_bookmark/no_origin')
    origin_uid=str(origin['uid'])
    fields=dict(bookId=book,chapters='0,'+origin_uid,bookType='epub',bookVersion=model['version'],
        pf='wechat_wx-2001-android-100-weread',pfkey='pfKey',zoneId=1,quote='',release=1,
        stopAutoPayWhenBNE=1,preload=2,preview=0,offline=1)
    native.archive_url=BASE+'/book/chapterdownload?'+urlencode(fields)
    archive,envelope=native.download(native.archive_url,credentials)
    decoded=read(archive,password(envelope,credentials['vid']),origin_uid)
    if not decoded['html']:raise ValueError('cross_bookmark/origin')
    return dict(book_id=book,uid=uid,book_version=model['version'],source_sha256=source['source_sha256'],
        origin_uid=origin_uid,origin_source_sha256=hashlib.sha256(decoded['source']).hexdigest())


def verify(probe,credentials,source,origin,target,runner,*,run=subprocess.run):
    if (not isinstance(runner,list) or not runner or len(runner)>40
            or any(not isinstance(part,str) or not part or len(part)>4096 for part in runner)
            or not isinstance(target,dict) or set(target)!={'id','sha256'}
            or any(origin.get(key)!=source[key] for key in ('book_id','uid','book_version','source_sha256'))):
        raise ValueError('cross_bookmark/input')
    actual,before=probe.read(credentials)
    if actual!=target:raise ValueError('cross_bookmark/target')
    row=before['marks']['updated'][target['id']]
    raw=probe.raw
    if hashlib.sha256(raw.encode()).hexdigest()!=source['source_sha256']:raise ValueError('cross_bookmark/source')
    point=from_mark(raw,source['book_id'],source['uid'],row)
    if point['chapter_offset']!=probe.first:raise ValueError('cross_bookmark/point')
    preview=project(raw,point['chapter_offset'])['markText']
    payload=dict(credentials=credentials,book_id=source['book_id'],uid=source['uid'],book_version=source['book_version'],
        source_sha256=source['source_sha256'],origin_uid=origin['origin_uid'],origin_source_sha256=origin['origin_source_sha256'],
        web_cookies=probe.source.payload['cookies'],cross_chapter=True,expect_bookmarks=True,expected_id=target['id'],expected_preview=preview)
    if source.get('mock_endpoint') is not None:payload['mock_endpoint']=source['mock_endpoint']
    expected=dict(id=target['id'],range=row['range'],text=preview)
    for width,height,dpi in SIZES:
        child=run(runner+['--width',str(width),'--height',str(height),'--dpi',str(dpi)],
            input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=240)
        if child.returncode or len(child.stdout)>131072 or child.stdout.count(FRAME)!=1:raise ValueError('cross_bookmark/runner')
        result=json.loads(child.stdout.split(FRAME,1)[1].splitlines()[0])
        fields={'result','rows','offline_reopen','credential_file_audit','installed_bytes_match','profile_removed','navigation','indicator'}
        if (set(result)!=fields or result['result']!='PASS' or result['rows']!=[expected]
                or not all(result[key] is True for key in fields-{'result','rows'})):
            raise ValueError('cross_bookmark/reader')
        current,after=probe.read(credentials)
        if current!=target or after!=before:raise ValueError('cross_bookmark/state_changed')
    return {'result':'PASS','screens':2,'offline_reopen':True,'source_point_verified':True,'indicator_tap_verified':True}
