"""Native zero-time position hypothesis; no I/O or upload authority.

Fields independently reconstructed from the Eink endpoint catalog and Moon
43b2181da6eb5285b62114da85e1413d2f8464e4 app.lua (GPL-3.0). Reuses the
project's attributed native signature implementation; licenses are retained
in integrations/licenses/readtime-sources.txt. No historical time is reported.
"""
from readtime_upload_model import sign,integer,zone
from verify_eink_renewal import validate_credentials
from source_upload_candidate import identifier


def body(credentials,point,version,guest,now,random,time_zone,chapter_progress=None):
    validate_credentials(credentials);identifier(point['book_id']);uid=identifier(str(point['chapter_uid']))
    if (not integer(int(uid),1,2**53-1) or not integer(version,0,2147483647) or not integer(now,1,4102444800) or not integer(random,0,999)
            or not integer(point['chapter_idx'],0,1000000) or not integer(point['chapter_offset'],0,2147483647)
            or type(point['raw_percent']) not in (int,float) or not 0<=point['raw_percent']<=100
            or not isinstance(point['summary'],str) or not 1<=len(point['summary'])<=512 or len(point['summary'].encode())>2048
            or any(ord(c)<32 and c not in '\t\r\n' for c in point['summary']) or not isinstance(guest,str) or not 1<=len(guest.encode())<=4096):raise ValueError('native_txt/body')
    tz=zone(time_zone)
    value=dict(appId=credentials['deviceId'],autoTime=0,bookId=point['book_id'],bookVersion=version,
        chapterIdx=point['chapter_idx'],chapterOffset=point['chapter_offset'],chapterUid=int(uid),currentProgress=point['raw_percent'],
        deviceId=credentials['deviceId'],hours=[],installId='',isLecture=0,isStoryFeed=0,lectureTextTime=0,lectureTime=0,novalTime=0,
        random=random,readingTime=0,recordCreateTimeZone=tz,reviewId='',risk=0,sourceModule='unknown',summary=point['summary'],timestamp=now,ttsTime=0,wordCount=0)
    if chapter_progress is not None:
        if type(chapter_progress) not in (int,float) or not 0<=chapter_progress<=100:raise ValueError('native_txt/chapter_progress')
        value['chapterProgress']=chapter_progress
    parts=[credentials['vid'],value['deviceId'],value['appId'],value['bookId'],'0',tz,'0','0']
    value['signature']=sign([guest,str(random),str(now),'_'.join(parts)])
    return value
