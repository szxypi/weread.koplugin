#!/usr/bin/env python3
"""Read-only native reading statistics prototype; offline by default.

The saved owner-approved native grant is used only for fixed GET statistics
queries. Personal durations, dates, titles and identities stay in memory;
reports contain response field names, types, counts and fixed assertions.
"""
import argparse
from datetime import datetime,timedelta,timezone
import json
import math
import re
import subprocess
from urllib.parse import parse_qs,urlencode,urlsplit

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore,StoreError
from verify_eink_login import BASE,NativeProbe,ProbeError

MODES=('weekly','monthly','annually','overall')


class StatisticsError(ValueError):pass


CST=timezone(timedelta(hours=8))


def numeric(value,maximum=1e12,minimum=0):
    return type(value) in (int,float) and math.isfinite(value) and minimum<=value<=maximum


def text(value,limit=4096):
    return isinstance(value,str) and len(value.encode('utf-8'))<=limit and not re.search(r'[\x00-\x1f\x7f]',value)


def period(mode,stamp):
    date=datetime.fromtimestamp(stamp,CST).replace(hour=0,minute=0,second=0,microsecond=0)
    if mode=='weekly':date-=timedelta(days=date.weekday());end=date+timedelta(days=7)
    elif mode=='monthly':
        date=date.replace(day=1)
        end=date.replace(year=date.year+1,month=1) if date.month==12 else date.replace(month=date.month+1)
    elif mode=='annually':date=date.replace(month=1,day=1);end=date.replace(year=date.year+1)
    else:return 0,4102444800
    return int(date.timestamp()),int(end.timestamp())


def project(raw,mode,base_time=0,now=None):
    now=datetime.now(timezone.utc).timestamp() if now is None else now
    if mode not in MODES or not isinstance(raw,dict) or not isinstance(raw.get('readTimes'),dict) or len(raw['readTimes'])>512:
        raise StatisticsError('statistics_invalid')
    if any(raw.get(k,0) not in (0,None,'0') for k in ('errcode','errCode')) or ('succ' in raw and raw['succ'] not in (True,1,'1')):
        raise StatisticsError('statistics_rejected')
    if not numeric(raw.get('totalReadTime')):raise StatisticsError('statistics_total_invalid')
    if not numeric(raw.get('readDays'),1e7) or raw['readDays']!=int(raw['readDays']):raise StatisticsError('statistics_days_invalid')
    expected,end=period(mode,base_time or now)
    if mode!='overall' and raw['readDays']>(end-expected)/86400:raise StatisticsError('statistics_days_outside_period')
    canonical=raw.get('baseTime')
    if mode!='overall' and (not numeric(canonical,4102444800) or canonical!=expected):raise StatisticsError('statistics_period_mismatch')
    out=dict(baseTime=expected,readTimes={},totalReadTime=raw['totalReadTime'])
    for key,value in raw['readTimes'].items():
        if not isinstance(key,str) or not re.fullmatch(r'[0-9]{9,13}',key) or not numeric(value):raise StatisticsError('statistics_bucket_invalid')
        stamp=int(key);stamp=stamp/1000 if stamp>=1e11 else stamp
        if stamp!=int(stamp) or not 0<=stamp<=4102444800 or (mode!='overall' and not expected<=stamp<end):
            raise StatisticsError('statistics_bucket_outside_period')
        unit='monthly' if mode=='annually' else 'annually' if mode=='overall' else 'daily'
        aligned=period(unit,stamp)[0] if unit!='daily' else int(datetime.fromtimestamp(stamp,CST).replace(hour=0,minute=0,second=0,microsecond=0).timestamp())
        if stamp!=aligned:raise StatisticsError('statistics_bucket_unaligned')
        normalized=str(int(stamp))
        if normalized in out['readTimes'] and out['readTimes'][normalized]!=value:raise StatisticsError('statistics_bucket_conflict')
        out['readTimes'][normalized]=value
    for name,maximum,minimum in (('readDays',1e7,0),('dayAverageReadTime',1e12,0),('compare',1e9,-1e9),('readRate',100,0)):
        if numeric(raw.get(name),maximum,minimum):out[name]=raw[name]
    for name in ('preferCategoryWord','preferTimeWord'):
        if text(raw.get(name),8192):out[name]=raw[name]
    if isinstance(raw.get('rank'),dict) and text(raw['rank'].get('text'),8192):out['rank']=dict(text=raw['rank']['text'])
    for name in ('readLongest','preferCategory','preferAuthor','preferPublisher','readStat'):
        value=raw.get(name)
        if value is None:continue
        if not isinstance(value,list) or len(value)>100:raise StatisticsError('statistics_list_invalid')
        rows=[]
        for row in value:
            if not isinstance(row,dict):continue
            if name=='readLongest':
                if not numeric(row.get('readTime')):continue
                result=dict(readTime=row['readTime'])
                for container,title,author in (('book','title','author'),('albumInfo','name','authorName')):
                    item=row.get(container)
                    if not isinstance(item,dict) or not text(item.get(title)) or not item[title]:continue
                    result[container]={title:item[title]}
                    if text(item.get(author)):result[container][author]=item[author]
                if len(result)>1:rows.append(result)
            elif name=='preferCategory':
                if text(row.get('categoryTitle')) and numeric(row.get('readingTime')):
                    result=dict(categoryTitle=row['categoryTitle'],readingTime=row['readingTime'])
                    if numeric(row.get('readingCount'),1e7):result['readingCount']=row['readingCount']
                    rows.append(result)
            elif name=='readStat':
                if text(row.get('stat'),256) and text(row.get('counts'),256):rows.append(dict(stat=row['stat'],counts=row['counts']))
            elif text(row.get('name')) and numeric(row.get('count'),1e7):rows.append(dict(name=row['name'],count=row['count']))
        out[name]=rows
    return out


def projections_equal(left,right):
    if isinstance(left,dict) and isinstance(right,dict):
        return set(left)==set(right) and all(projections_equal(left[k],right[k]) for k in left)
    if isinstance(left,list) and isinstance(right,list):
        return len(left)==len(right) and all(projections_equal(a,b) for a,b in zip(left,right))
    if type(left) in (int,float) and type(right) in (int,float):
        return math.isclose(left,right,rel_tol=0,abs_tol=1e-9)
    return type(left) is type(right) and left==right


def schema(value):
    if not isinstance(value,dict):raise StatisticsError('statistics_invalid')
    result=dict(field_names=sorted(value))
    for name in ('readTimes','dailyReadTimes'):
        data=value.get(name)
        kind='missing' if data is None else type(data).__name__
        entry=dict(type=kind)
        if isinstance(data,dict):
            entry['count']=len(data)
            entry['value_types']=sorted({type(v).__name__ for v in data.values()})
            keys=list(data)
            entry['key_format']='unix' if all(isinstance(k,str) and re.fullmatch(r'[0-9]{9,13}',k) for k in keys) else 'date' if all(isinstance(k,str) and re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}',k) for k in keys) else 'other'
        elif isinstance(data,list):
            entry['count']=len(data)
            entry['row_field_names']=sorted({key for row in data if isinstance(row,dict) for key in row})
        result[name]=entry
    return result


class StatisticsProbe(NativeProbe):
    def guard(self,stage,url,body):
        parsed=urlsplit(url);query=parse_qs(parsed.query,keep_blank_values=True)
        if (body is not None or parsed.scheme!='https' or parsed.netloc!='i.weread.qq.com' or parsed.fragment
                or parsed.path!='/readdata/detail' or set(query)!={'mode','baseTime'} or any(len(v)!=1 for v in query.values())):
            raise StatisticsError('statistics_request_outside_scope')
        mode=query['mode'][0];base=query['baseTime'][0]
        if mode not in MODES or stage!='statistics_'+mode or not base.isascii() or not base.isdigit() or not 0<=int(base)<=4102444800:
            raise StatisticsError('statistics_request_outside_scope')

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        self.guard(stage,url,body)
        return super().request(stage,url,body,credentials,timeout)

    def inspect(self,credentials):
        self.samples=[]
        rows=[]
        now=datetime.now(timezone.utc).timestamp()
        current_month=period('monthly',now)[0]
        previous_month=period('monthly',current_month-1)[0]
        for mode,base in [(m,0) for m in MODES]+[('monthly',previous_month)]:
            source=self.request('statistics_'+mode,BASE+'/readdata/detail?'+urlencode(dict(mode=mode,baseTime=base)),credentials=credentials)
            expected=project(source,mode,base,now)
            rows.append(dict(mode=mode,historical=base!=0,**schema(source),period_verified=True,
                             total_matches_buckets=sum(expected['readTimes'].values())==expected['totalReadTime'],
                             projected_field_names=sorted(expected)))
            if mode in ('weekly','monthly'):rows[-1]['days_match_positive_daily_buckets']=expected['readDays']==sum(v>0 for v in expected['readTimes'].values())
            self.samples.append(dict(mode=mode,base_time=base,source=source,expected=expected,now=now))
        return dict(responses=rows)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if (args.native_http and not (args.saved_session and args.lua_command)) or (args.lua_command and not args.saved_session):
        parser.error('Lua comparison requires --saved-session; --native-http also requires --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_writes_attempted=0,
                private_statistics_saved=False,credentials_written_to_files=False)
    if not args.saved_session:
        assert schema(dict(readTimes={}))['readTimes']['count']==0
        print(json.dumps(report,indent=2));return 0
    credentials=None;probe=None
    try:
        credentials=NativeSessionStore().load(SessionStore().load()['vid'])
        probe=StatisticsProbe()
        report.update(probe.inspect(credentials))
        if args.lua_command:
            payload=dict(samples=probe.samples)
            if args.native_http:payload['credentials']=credentials
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>2*1024*1024:raise StatisticsError('statistics_probe_input_too_large')
            child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            frame=b'\nWEREAD_STATISTICS_RESULT='
            if child.returncode or len(child.stdout)>2*1024*1024 or child.stdout.count(frame)!=1:raise StatisticsError('statistics_lua_probe_failed')
            actual=json.loads(child.stdout.split(frame)[1])
            expected=[s['expected'] for s in probe.samples]
            for group in ('model','native'):
                for value in actual.get(group,[]):
                    for key in ('readLongest','preferCategory','preferAuthor','preferPublisher','readStat'):
                        if value.get(key)=={}:value[key]=[]
            if not projections_equal(actual.get('model'),expected):
                report['projection_differences']=[dict(mode=sample['mode'],fields=sorted(key for key in set(value)|set(target) if value.get(key)!=target.get(key)))
                    for sample,value,target in zip(probe.samples,actual.get('model',[]),expected) if value!=target]
                raise StatisticsError('statistics_lua_projection_mismatch')
            report['lua_projection_matches']=True
            report['json_numeric_absolute_tolerance']=1e-9
            if args.native_http:
                if not projections_equal(actual.get('native'),expected) or actual.get('requests')!=len(expected):raise StatisticsError('statistics_native_readback_mismatch')
                report.update(native_https_projection_matches=True,native_read_requests=actual['requests'])
        report.update(result='NATIVE_STATISTICS_CONTRACT_VERIFIED',same_owner_verified=True,stages=probe.report['stages'])
    except (StoreError,ProbeError,StatisticsError) as exc:report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:report.update(result='UNVERIFIED',reason='statistics_verification_failed')
    finally:
        if credentials:credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result']=='NATIVE_STATISTICS_CONTRACT_VERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
