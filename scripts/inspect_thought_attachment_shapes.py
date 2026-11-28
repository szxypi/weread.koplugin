#!/usr/bin/env python3
"""Bounded read-only survey of personal thought attachment shapes.

Only counts and known field names are reported. Credentials, book IDs, note
text, image URLs and complete responses remain in memory and are not logged.
"""
import argparse
import json
import resource
import time
from collections import Counter
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, build_opener

from my_cloud_marks_model import identifier
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE, NativeProbe, NoRedirect
from verify_my_cloud_thoughts import inspect_scope

PICTURE_FIELDS=('url','src','imageUrl','pictureUrl','width','height')
PENCIL_FIELDS=('imageUrl','drawingUrl','andDrawingUrl','doddleDrawingUrl','imageWidth','imageHeight')


def shape(value):
    if value is None:return 'null'
    if isinstance(value,bool):return 'boolean'
    if isinstance(value,str):return 'string' if value else 'empty_string'
    if isinstance(value,list):return 'array' if value else 'empty_array'
    if isinstance(value,dict):return 'object' if value else 'empty_object'
    if isinstance(value,(int,float)):return 'number'
    return 'other'


def classify_url(value):
    if not isinstance(value,str) or not value:return 'absent'
    try:
        url=urlsplit(value if not value.startswith('//') else 'https:'+value)
        host=(url.hostname or '').lower()
        if url.scheme!='https' or url.username or url.password or url.fragment:return 'other'
        if host=='weread-picture-1258476243.file.myqcloud.com':return 'weread_picture_bucket'
        return 'tencent_cloud' if host.endswith('.myqcloud.com') else 'other'
    except ValueError:return 'other'


def summarize(reviews):
    counts=Counter();picture_fields=Counter();pencil_fields=Counter();url_types=Counter()
    for wrapper in reviews:
        if not isinstance(wrapper,dict) or not isinstance(wrapper.get('review'),dict):raise ValueError('rows')
        row=wrapper['review'];counts['rows']+=1
        for name in ('pictures','pencilNote'):
            if name in row:counts[name+'_'+shape(row[name])]+=1
        content=row.get('htmlContent')
        if isinstance(content,str) and '<img' in content.lower():counts['html_with_image']+=1
        pictures=row.get('pictures')
        if isinstance(pictures,list):
            if len(pictures)>100:raise ValueError('picture_limit')
            for image in pictures:
                counts['picture_item_'+shape(image)]+=1
                if isinstance(image,str):url_types[classify_url(image)]+=1
                if isinstance(image,dict):
                    for key in PICTURE_FIELDS:
                        if key in image:
                            picture_fields[key+'_'+shape(image[key])]+=1
                            if key in PICTURE_FIELDS[:4]:url_types[classify_url(image[key])]+=1
        pencil=row.get('pencilNote')
        if isinstance(pencil,dict):
            for key in PENCIL_FIELDS:
                if key in pencil:
                    pencil_fields[key+'_'+shape(pencil[key])]+=1
                    if key in PENCIL_FIELDS[:4]:url_types[classify_url(pencil[key])]+=1
    return counts,picture_fields,pencil_fields,url_types


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--public-sample',action='store_true');args=parser.parse_args()
    if args.public_sample and not args.saved_session:parser.error('public sample requires saved session')
    report={'result':'OFFLINE_ONLY','account_data_writes':0,'authentication_posts':0,'private_values_saved':False}
    if not args.saved_session:print(json.dumps(report));return 0
    credentials=saved=None
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid']);client=NativeProbe()
        notebooks=client.request('notebooks',BASE+'/user/notebooks?count=100',credentials=credentials)
        rows=notebooks.get('books')
        if not isinstance(rows,list) or len(rows)>100:raise ValueError('notebooks')
        ids=[]
        for row in rows:
            if not isinstance(row,dict):raise ValueError('notebooks')
            book=row.get('book',row);ident=str(book.get('bookId','')) if isinstance(book,dict) else ''
            count=row.get('reviewCount',0)
            if type(count) is int and count>0 and identifier(ident):ids.append(ident)
        if len(ids)!=len(set(ids)):raise ValueError('notebooks')
        counters=[Counter() for _ in range(4)];complete=0
        for ident in ids[:25]:
            url=BASE+'/review/list?'+urlencode(dict(bookId=ident,listType=11,listMode=0,mine=1,synckey=0,count=100))
            source=client.request('thoughts',url,credentials=credentials)
            scope=inspect_scope(source,ident,credentials['vid'])
            if not scope['books_match'] or not scope['owners_match'] or scope['rows'] and not scope['owner_fields']:
                raise ValueError('scope')
            if type(source.get('totalCount')) is int and source['totalCount']==scope['rows']:complete+=1
            for counter,extra in zip(counters,summarize(source['reviews'])):counter.update(extra)
            time.sleep(.2)
        public=[Counter() for _ in range(4)];public_books=0;public_sample=None
        if args.public_sample:
            shelf=client.request('shelf',BASE+'/shelf/sync',credentials=credentials)
            if not isinstance(shelf.get('books'),list):raise ValueError('shelf')
            selected=[]
            for row in shelf['books']:
                ident=str(row.get('bookId','')) if isinstance(row,dict) else ''
                if identifier(ident) and ident not in selected:selected.append(ident)
                if len(selected)==5:break
            for ident in selected:
                query=dict(bookId=ident,listType=3,listMode=1,synckey=0,count=41,maxIdx=0,tips=1)
                response=client.request('reviews',BASE+'/review/list?'+urlencode(query),credentials=credentials)
                reviews=response.get('reviews')
                if not isinstance(reviews,list) or len(reviews)>41:raise ValueError('public_reviews')
                if any(not isinstance(row,dict) or not isinstance(row.get('review'),dict)
                    or str(row['review'].get('bookId'))!=ident for row in reviews):raise ValueError('public_scope')
                for counter,extra in zip(public,summarize(reviews)):counter.update(extra)
                for wrapper in reviews:
                    for picture in wrapper['review'].get('pictures',[]) if isinstance(wrapper['review'].get('pictures'),list) else []:
                        url=picture.get('url') if isinstance(picture,dict) else None
                        if public_sample is None and classify_url(url)=='weread_picture_bucket':public_sample=url
                public_books+=1;time.sleep(.2)
        report.update(result='THOUGHT_ATTACHMENT_SHAPES_READ',notebooks_returned=len(rows),books_checked=min(len(ids),25),
            complete_books=complete,more_books_not_checked=len(ids)>25,counts=dict(counters[0]),
            picture_fields=dict(counters[1]),pencil_fields=dict(counters[2]),url_types=dict(counters[3]))
        if args.public_sample:report.update(public_books=public_books,public_counts=dict(public[0]),
            public_picture_fields=dict(public[1]),public_pencil_fields=dict(public[2]),public_url_types=dict(public[3]))
        if public_sample:
            request=Request(public_sample,headers={'Accept':'image/*','Referer':'https://weread.qq.com/'})
            with build_opener(NoRedirect()).open(request,timeout=20) as response:
                raw=response.read(4*1024*1024+1)
                kind=('png' if raw.startswith(b'\x89PNG\r\n\x1a\n') else 'jpeg' if raw.startswith(b'\xff\xd8\xff')
                    else 'gif' if raw.startswith((b'GIF87a',b'GIF89a')) else 'webp' if raw[:4]==b'RIFF' and raw[8:12]==b'WEBP' else None)
                if response.status!=200 or not kind or len(raw)>4*1024*1024:raise ValueError('image')
                report['public_sample_image']={'anonymous_download_verified':True,'format':kind,'bytes':len(raw)}
    except Exception as error:
        report.update(result='UNVERIFIED',reason='auth_expired' if 'HTTP 401' in str(error) else 'unavailable')
    finally:
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,sort_keys=True))
    return 0 if report['result']=='THOUGHT_ATTACHMENT_SHAPES_READ' else 1


if __name__=='__main__':raise SystemExit(main())
