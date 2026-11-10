#!/usr/bin/env python3
"""Owner statistics pages/cache/fresh offline process. Offline by default.

Only --saved-session --lua-command opts into bounded native statistics GETs.
No data/authentication POSTs, renewal, screenshots or private disk reports.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess
from urllib.parse import urlencode

from owner_statistics_contract import decode_runner
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE
from verify_native_statistics import StatisticsProbe,StatisticsError,CST,period,project

DAY=86400


def streak(months,now):
    cursor=(int(now)+28800)//DAY*DAY-28800;count=0
    current=months.get(str(period('monthly',cursor)[0]))
    if current is None:return 0,True,period('monthly',cursor)[0]
    if current['daily'].get(str(cursor),0)<=0:cursor-=DAY
    for _i in range(24*366):
        base=period('monthly',cursor)[0];month=months.get(str(base))
        if month is None:return count,True,base
        if month['daily'].get(str(cursor),0)<=0:return count,False,None
        count+=1;cursor-=DAY
    return count,True,None


def profile_display(months,now):
    base,end=period('monthly',now);today=(int(now)+28800)//DAY*DAY-28800;month=months[str(base)]
    count,lower,_missing=streak(months,now);days=[]
    for stamp in range(base,end,DAY):
        date=datetime.fromtimestamp(stamp,CST)
        days.append(dict(day=date.day,seconds=month['daily'].get(str(stamp),0) if stamp<=today else 0,
                         future=stamp>today,today=stamp==today,known=stamp<=today))
    return dict(profile=True,has_data=True,mode='monthly',period_label=datetime.fromtimestamp(base,CST).strftime('%Y-%m'),
                goal_minutes=45,today_seconds=month['daily'].get(str(today),0),month_seconds=month['total'],
                month_read_days=month['read_days'],streak=count,streak_lower_bound=lower,days=days,
                first_weekday=datetime.fromtimestamp(base,CST).isoweekday())


def statistics_display(raw,mode,now):
    output=dict(mode=mode,total_read_time=raw['totalReadTime'],read_days=raw['readDays'],day_average=raw.get('dayAverageReadTime',0),
                buckets=[],top_books=[],prefer_category=[],prefer_author=[],prefer_publisher=[],summary=[],
                base_time=raw['baseTime'],source_kind='native',allow_prev=mode!='overall')
    for key in ('compare','readRate','preferCategoryWord','preferTimeWord'):
        if key in raw:output[{'readRate':'read_rate','preferCategoryWord':'prefer_category_word','preferTimeWord':'prefer_time_word'}.get(key,key)]=raw[key]
    for stamp,seconds in sorted(raw['readTimes'].items(),key=lambda pair:int(pair[0])):
        date=datetime.fromtimestamp(int(stamp),CST);label=str(date.month) if mode=='annually' else str(date.year) if mode=='overall' else str(date.day)
        output['buckets'].append(dict(ts=int(stamp),label=label,value=seconds))
    for row in raw.get('readLongest',[]):
        book=row.get('book',{});album=row.get('albumInfo',{});title=book.get('title') or album.get('name')
        item=dict(title=title,seconds=row['readTime']);author=book.get('author') if book.get('author') is not None else album.get('authorName')
        if author is not None:item['author']=author
        output['top_books'].append(item)
    for row in raw.get('preferCategory',[]):
        if row['categoryTitle']!='':output['prefer_category'].append(dict(title=row['categoryTitle'],seconds=row['readingTime'],count=row.get('readingCount',0)))
    for source,target in [('preferAuthor','prefer_author'),('preferPublisher','prefer_publisher')]:
        output[target]=[dict(name=row['name'],count=row['count']) for row in raw.get(source,[]) if row['name']!='']
    output['summary']=[dict(name=row['stat'],counts=row['counts']) for row in raw.get('readStat',[])]
    if 'rank' in raw:output['rank_text']=raw['rank']['text']
    if mode=='overall':output.update(period_label='',allow_next=False)
    else:
        base,end=period(mode,raw['baseTime']);date=datetime.fromtimestamp(base,CST)
        label=date.strftime('%Y') if mode=='annually' else date.strftime('%Y-%m') if mode=='monthly' else date.strftime('%Y-%m-%d')+' ~ '+datetime.fromtimestamp(base+6*DAY,CST).strftime('%m-%d')
        output.update(period_label=label,prev_base_time=period(mode,base-1)[0],next_base_time=end,allow_next=end<=now)
    return output


def prepare(credentials,probe,now=None):
    now=int(datetime.now(timezone.utc).timestamp()) if now is None else now
    cache={};rules={};months={};profile=[]
    def fetch(mode,base):
        key=f'{mode}:{base}'
        if key not in cache:
            source=probe.request('statistics_'+mode,BASE+'/readdata/detail?'+urlencode(dict(mode=mode,baseTime=base)),credentials=credentials)
            cache[key]=project(source,mode,base,now)
        rules[key]=rules.get(key,0)+1
        return cache[key]
    base=period('monthly',now)[0]
    for _i in range(24):
        raw=fetch('monthly',base)
        months[str(base)]=dict(base=base,daily=raw['readTimes'],total=raw['totalReadTime'],read_days=raw['readDays'])
        profile.append(base);_count,lower,missing=streak(months,now)
        if not lower or missing is None:break
        base=missing
    details=[];previous=period('monthly',period('monthly',now)[0]-1)[0]
    current=period('monthly',now)[0]
    for mode,base in [('monthly',0),('monthly',previous),('monthly',current),('weekly',0),('annually',0),('overall',0)]:
        raw=fetch(mode,base);details.append(dict(mode=mode,base_time=base,raw=raw,display=statistics_display(raw,mode,now)))
    latest={(row['mode'],row['raw']['baseTime']):row['raw'] for row in details}
    for row in details:
        row['offline_raw']=latest[row['mode'],row['raw']['baseTime']]
        row['offline_display']=statistics_display(row['offline_raw'],row['mode'],now)
    return dict(credentials=credentials,now=now,profile_months=profile,profile_snapshot=months,
                profile_display=profile_display(months,now),details=details,
                rules=[dict(mode=key.split(':')[0],base_time=int(key.split(':')[1]),count=count) for key,count in rules.items()])


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('pair --saved-session and --lua-command; put --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                authentication_posts_attempted=0,screenshots=0,private_data_on_regular_disk=False,credentials_written_to_files=False)
    credentials=payload=probe=None
    try:
        if args.saved_session:
            owner=SessionStore().load()['vid'];credentials=NativeSessionStore().load(owner)
            probe=StatisticsProbe();payload=prepare(credentials,probe);encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>2*1024*1024:raise StatisticsError('owner_statistics_input_limit')
            child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=320)
            result=decode_runner(child.stdout);report['ui']=result
            if child.returncode or result['result']!='PASS':raise StatisticsError('owner_statistics_ui_unverified')
            if result['stages'][0]['request_counts']!=[row['count'] for row in payload['rules']]:raise StatisticsError('owner_statistics_requests_unverified')
            if result['stages'][0]['profile_months']!=len(payload['profile_months']):raise StatisticsError('owner_statistics_profile_unverified')
            report.update(result='OWNER_STATISTICS_FILE_UI_AND_OFFLINE_VERIFIED',same_owner_verified=True,
                          python_preflight_gets=len(probe.report['stages']),profile_months=len(payload['profile_months']))
    except KeyboardInterrupt:report.update(result='UNVERIFIED',reason='owner_statistics_interrupted')
    except Exception:report.update(result='UNVERIFIED',reason='owner_statistics_verification_failed')
    finally:
        if probe:report['preflight_stages']=[{k:v for k,v in row.items() if k in ('stage','status','error_code')} for row in probe.report['stages']]
        if credentials:credentials.clear()
        if payload:payload.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','OWNER_STATISTICS_FILE_UI_AND_OFFLINE_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
