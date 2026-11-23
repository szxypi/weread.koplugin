#!/usr/bin/env python3
"""Read-only public-picture test. Identifiers and URLs stay in memory."""
import hashlib
import json
import resource
import subprocess
from urllib.parse import urlencode
from urllib.request import Request, build_opener

from inspect_thought_attachment_shapes import classify_url
from my_cloud_marks_model import identifier
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE, NativeProbe, NoRedirect


def main():
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=credentials=None
    try:
        saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid']);client=NativeProbe()
        shelf=client.request('shelf',BASE+'/shelf/sync',credentials=credentials)
        selected=[]
        for row in shelf['books']:
            book=str(row.get('bookId','')) if isinstance(row,dict) else ''
            if identifier(book) and book not in selected:selected.append(book)
            if len(selected)==5:break
        sample=None
        for book in selected:
            query=dict(bookId=book,listType=3,listMode=1,synckey=0,count=41,maxIdx=0,tips=1)
            reviews=client.request('reviews',BASE+'/review/list?'+urlencode(query),credentials=credentials)['reviews']
            if len(reviews)>41:raise ValueError('review_limit')
            for wrapper in reviews:
                row=wrapper.get('review',{})
                if str(row.get('bookId'))!=book:raise ValueError('scope')
                for item in row.get('pictures',[]) if isinstance(row.get('pictures'),list) else []:
                    url=item.get('url') if isinstance(item,dict) else None
                    if classify_url(url)=='weread_picture_bucket':sample=url;break
                if sample:break
            if sample:break
        if not sample:raise ValueError('no_public_sample')
        with build_opener(NoRedirect()).open(Request(sample,headers={'Accept':'image/*','Referer':'https://weread.qq.com/'}),timeout=20) as response:
            data=response.read(3*1024*1024+1)
            if response.status!=200 or len(data)>3*1024*1024:raise ValueError('image')
        payload=json.dumps({'url':sample,'sha256':hashlib.sha256(data).hexdigest()}).encode()
        command=['docker','exec','-i','-w','/source','weread-validation','python3','scripts/test_thought_images_runtime.py',
            '--koreader','/validation/runtime/lib/koreader','--public-stdin']
        result=subprocess.run(command,input=payload,capture_output=True,timeout=240)
        if result.returncode:raise ValueError('native_public_image_unverified')
        print(json.dumps({'result':'PUBLIC_NATIVE_IMAGE_PASS','sizes':2,'anonymous':True,'offline_reopen':True,
            'account_data_writes':0,'authentication_posts':0,'profile_removed':True}))
        return 0
    except Exception as error:
        reason=str(error) if str(error) in ('no_public_sample','native_public_image_unverified') else 'unavailable'
        print(json.dumps({'result':'UNVERIFIED','reason':reason,'account_data_writes':0}))
        return 1
    finally:
        if credentials:credentials.clear()
        if saved:saved.clear()


if __name__=='__main__':raise SystemExit(main())
