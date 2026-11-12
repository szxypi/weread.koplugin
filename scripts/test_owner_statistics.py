"""Offline reference models, redaction and owner UI opt-in boundaries."""
from contextlib import redirect_stdout,redirect_stderr
from datetime import datetime
import io
import json
import subprocess
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs,urlsplit

from mock_weread import reading_statistics
from owner_statistics_contract import FLAGS,FRAME,decode_runner,decode_stage,validate_stage
from test_secure_native_session import credentials
from verify_native_statistics import CST
from verify_owner_statistics import main,prepare,profile_display,statistics_display,streak,account_name,NameProbe


def stamp(year,month,day):return int(datetime(year,month,day,tzinfo=CST).timestamp())


class Probe:
    def __init__(self,now,long_streak=False):self.now=now;self.report={'stages':[]};self.requests=[];self.long_streak=long_streak
    def request(self,stage,url,credentials=None):
        query=parse_qs(urlsplit(url).query);mode=query['mode'][0];base=int(query['baseTime'][0])
        self.requests.append((mode,base));self.report['stages'].append(dict(stage=stage,status=200))
        value=reading_statistics(mode,base or self.now)
        if self.long_streak and mode=='monthly':value['readTimes']={key:max(1,seconds) for key,seconds in value['readTimes'].items()}
        return value


def stage(mode='live'):
    return dict(result='PASS',mode=mode,phase='complete',worker_http_child=mode=='live',profile_months=1,
        validated_views=7,detail_periods=6,calendar_days=30,calendar_cells=35,profile_files_audited=5,
        screenshots=0,forbidden_requests=0,failed_line=0,account_name_present=False,request_counts=[2,1,1,1,1,1] if mode=='live' else [0]*6,
        **dict.fromkeys(FLAGS,True))


def envelope():return dict(result='PASS',tmpfs_profile=True,profile_removed=True,stages=[stage(),stage('reopen')],runner_error='none',installed_files=236,installed_bytes_match=True)


class StatisticsModelTests(unittest.TestCase):
    def test_account_name_is_owner_bound_bounded_and_plain_text(self):
        self.assertEqual(account_name(dict(vid=900000,name='合成读者 Native'),'900000'),'合成读者 Native')
        for raw in [dict(vid='900001',name='Private'),dict(vid='900000',name=''),dict(vid='900000',name=' '),
                    dict(vid='900000',name='bad\nname'),dict(vid='900000',name='x'*257),dict(vid='900000',name='中'*171)]:
            with self.subTest(raw=raw),self.assertRaises(ValueError):account_name(raw,'900000')

    def test_name_probe_cannot_read_other_routes_or_mutate_data(self):
        probe=NameProbe();probe.vid='900000'
        with patch('verify_owner_statistics.WebSourceProbe.request',return_value=dict(vid='900000',name='Synthetic')) as request:
            probe.verify_account();self.assertEqual(probe.name,'Synthetic')
            for stage_name in ('shelf','web_renewal','auth_page','reader'):
                with self.assertRaises(ValueError):probe.request(stage_name,'https://weread.qq.com/')
            self.assertEqual(request.call_count,1)
        probe.close()

    def test_cross_leap_month_streak_and_future_days(self):
        now=stamp(2024,3,1);march=stamp(2024,3,1);feb=stamp(2024,2,1)
        months={str(march):dict(base=march,daily={str(march):0,str(march+86400):999},total=1234,read_days=9)}
        self.assertEqual(streak(months,now),(0,True,feb))
        months[str(feb)]=dict(base=feb,daily={str(stamp(2024,2,29)):20,str(stamp(2024,2,28)):30},total=50,read_days=2)
        self.assertEqual(streak(months,now),(2,False,None))
        display=profile_display(months,now)
        self.assertEqual(display['month_seconds'],1234);self.assertEqual(display['month_read_days'],9)
        self.assertEqual(display['days'][1],dict(day=2,seconds=0,future=True,today=False,known=False))

    def test_today_activity_and_zero_day_termination(self):
        now=stamp(2026,11,10);base=stamp(2026,11,1)
        months={str(base):dict(base=base,daily={str(now):10,str(now-86400):0},total=99,read_days=5)}
        self.assertEqual(streak(months,now),(1,False,None))
        display=profile_display(months,now);self.assertEqual(display['today_seconds'],10)
        self.assertEqual(display['first_weekday'],7)

    def test_detail_mapping_keeps_server_totals_and_view_field_names(self):
        base=stamp(2026,11,1)
        raw=dict(baseTime=base,readTimes={str(base):100},totalReadTime=999,readDays=20,
            readLongest=[dict(book=dict(title='Private title',author=''),albumInfo=dict(name='Other title',authorName='Album author'),readTime=55)],
            preferCategory=[dict(categoryTitle='Category',readingTime=45)],preferAuthor=[dict(name='',count=4),dict(name='Author',count=2)],
            preferTimeWord='Private habit',rank=dict(text='Private rank'),readStat=[dict(stat='Read',counts='2')])
        data=statistics_display(raw,'monthly',base+86400)
        self.assertEqual(data['total_read_time'],999);self.assertEqual(data['read_days'],20)
        self.assertEqual(data['prefer_category'],[dict(title='Category',seconds=45,count=0)])
        self.assertEqual(data['top_books'],[dict(title='Private title',author='',seconds=55)])
        self.assertEqual(data['prefer_author'],[dict(name='Author',count=2)]);self.assertFalse(data['allow_next'])

    def test_python_queries_deduplicated_and_native_quotas_bound(self):
        now=stamp(2026,11,10);probe=Probe(now);payload=prepare(credentials(),probe,now)
        self.assertEqual(len(probe.requests),len(set(probe.requests)))
        self.assertEqual(sum(row['count'] for row in payload['rules']),len(payload['profile_months'])+6)
        self.assertEqual(len(payload['details']),6);self.assertEqual(payload['profile_display']['goal_minutes'],45)
        self.assertEqual([row['mode'] for row in payload['details']],['monthly','monthly','monthly','weekly','annually','overall'])

    def test_previous_month_read_twice_by_distinct_profile_and_detail_flows(self):
        now=stamp(2024,3,1);probe=Probe(now);payload=prepare(credentials(),probe,now)
        self.assertEqual(payload['profile_months'],[stamp(2024,3,1),stamp(2024,2,1)])
        previous=[row for row in payload['rules'] if row['mode']=='monthly' and row['base_time']==stamp(2024,2,1)]
        self.assertEqual(previous[0]['count'],2);self.assertEqual(payload['profile_display']['streak'],2)

    def test_maximum_backfill_stops_at24_and_keeps30_native_get_quota(self):
        now=stamp(2026,11,10);probe=Probe(now,long_streak=True);payload=prepare(credentials(),probe,now)
        self.assertEqual(len(payload['profile_months']),24)
        self.assertEqual(len(probe.requests),28)
        self.assertEqual(sum(row['count'] for row in payload['rules']),30)
        self.assertTrue(payload['profile_display']['streak_lower_bound'])

    def test_offline_same_period_uses_last_snapshot_after_returning_from_history(self):
        now=stamp(2026,11,10)
        class VaryingProbe(Probe):
            def request(self,stage,url,credentials=None):
                value=super().request(stage,url,credentials);query=parse_qs(urlsplit(url).query)
                if query['mode'][0]=='monthly':value['compare']=1 if query['baseTime']==['0'] else 2
                return value
        payload=prepare(credentials(),VaryingProbe(now),now)
        self.assertEqual(payload['details'][0]['display']['compare'],1)
        self.assertEqual(payload['details'][2]['display']['compare'],2)
        self.assertEqual(payload['details'][0]['offline_display']['compare'],2)


class ContractTests(unittest.TestCase):
    def test_live_and_fresh_offline_receipts(self):
        for mode in ('live','reopen'):self.assertEqual(decode_stage(FRAME+json.dumps(stage(mode)).encode(),mode),stage(mode))
        self.assertEqual(decode_runner(FRAME+json.dumps(envelope()).encode()),envelope())

    def test_every_acceptance_flag_required(self):
        for key in FLAGS:
            value=stage();value[key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(value,'live')

    def test_private_or_unknown_fields_rejected(self):
        for key in ['credentials','owner','dates','duration','titles','raw']:
            value=stage();value[key]='private'
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(value,'live')

    def test_invalid_counter_and_status_types_rejected(self):
        for key,bad in [('result',True),('phase',[]),('calendar_days',True),('calendar_cells',43),('profile_months',25),
                        ('screenshots',1),('forbidden_requests',1),('failed_line',1),('request_counts',[True]*6),('request_counts',[1]*30)]:
            value=stage();value[key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(value,'live')

    def test_offline_network_or_incomplete_runner_never_pass(self):
        value=stage('reopen');value['request_counts'][0]=1
        with self.assertRaises(ValueError):validate_stage(value,'reopen')
        for key,bad in [('profile_removed',False),('tmpfs_profile',False),('stages',[stage()]),('installed_files',0),('installed_bytes_match',False)]:
            value=envelope();value[key]=bad
            with self.assertRaises(ValueError):decode_runner(FRAME+json.dumps(value).encode())
        value=envelope();value['stages'][1]['calendar_cells']=42
        with self.assertRaises(ValueError):decode_runner(FRAME+json.dumps(value).encode())
        value=envelope();value['stages'][1]['account_name_present']=True
        with self.assertRaises(ValueError):decode_runner(FRAME+json.dumps(value).encode())

    def test_duplicate_or_unbounded_frames_rejected(self):
        for raw in [b'no frame',FRAME+b'{}'+FRAME+b'{}',b'x'*(65536+1)]:
            with self.assertRaises(ValueError):decode_runner(raw)


class CliTests(unittest.TestCase):
    def test_offline_default_and_invalid_arguments_do_not_open_keychain(self):
        with patch('verify_owner_statistics.SessionStore') as store,patch('verify_owner_statistics.StatisticsProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();probe.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        for arguments in [['--saved-session'],['--lua-command','missing'],['--verify-account-name']]:
            with patch('verify_owner_statistics.SessionStore') as store,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(arguments)
            store.assert_not_called()

    def execute(self,response,*,returncode=0,named=False,changed_name=False):
        grant=credentials();payload=dict(credentials=grant,rules=[dict(count=n) for n in [2,1,1,1,1,1]],profile_months=[1]);probe=Probe(stamp(2026,11,10))
        with patch('verify_owner_statistics.SessionStore') as web,patch('verify_owner_statistics.NativeSessionStore') as native,\
             patch('verify_owner_statistics.StatisticsProbe',return_value=probe),patch('verify_owner_statistics.prepare',return_value=payload),\
             patch('verify_owner_statistics.NameProbe') as names,patch('verify_owner_statistics.save_refreshed_web_session',return_value=False) as rotation,\
             patch('verify_owner_statistics.subprocess.run') as child,redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key'));native.return_value.load.return_value=grant
            names.return_value.name='PRIVATE_PROFILE_NAME_CANARY'
            names.return_value.report={'stages':[dict(stage='account',status=200)]*2}
            if changed_name:
                values=iter(['PRIVATE_PROFILE_NAME_CANARY','CHANGED_PRIVATE_PROFILE_NAME'])
                names.return_value.verify_account.side_effect=lambda:setattr(names.return_value,'name',next(values))
            if isinstance(response,Exception):child.side_effect=response
            else:child.return_value=subprocess.CompletedProcess([],returncode,FRAME+json.dumps(response).encode(),b'private stderr')
            code=main(['--saved-session']+(['--verify-account-name'] if named else [])+['--lua-command','controlled-runner'])
            if named:
                rotation.assert_called_once()
                self.assertEqual(json.loads(child.call_args.kwargs['input'])['account_name'],'PRIVATE_PROFILE_NAME_CANARY')
        self.assertEqual(grant,{})
        for secret in ['synthetic-native-access','synthetic-native-refresh','private stderr','"900000"','PRIVATE_PROFILE_NAME_CANARY','CHANGED_PRIVATE_PROFILE_NAME']:
            self.assertNotIn(secret,out.getvalue())
        native.return_value.delete.assert_not_called();web.return_value.delete.assert_not_called()
        return code,json.loads(out.getvalue())

    def test_valid_receipts_pass_without_exposing_private_data(self):
        code,value=self.execute(envelope());self.assertEqual(code,0)
        self.assertEqual(value['result'],'OWNER_STATISTICS_FILE_UI_AND_OFFLINE_VERIFIED')

    def test_real_name_mode_requires_rendered_receipts_and_redacts_the_name(self):
        response=envelope()
        for row in response['stages']:row['account_name_present']=True
        code,value=self.execute(response,named=True)
        self.assertEqual(code,0);self.assertTrue(value['account_name_verified'])
        code,value=self.execute(envelope(),named=True)
        self.assertEqual(code,1);self.assertEqual(value['result'],'UNVERIFIED')

    def test_name_change_stops_acceptance_but_keeps_verified_cookie_rotation(self):
        response=envelope()
        for row in response['stages']:row['account_name_present']=True
        code,value=self.execute(response,named=True,changed_name=True)
        self.assertEqual(code,1);self.assertEqual(value['reason'],'owner_profile_name_unverified')

    def test_mismatched_quota_failure_and_timeout_are_sanitized(self):
        value=envelope();value['stages'][0]['request_counts']=[1,2,1,1,1,1]
        for response in [value,dict(envelope(),credentials='private'),subprocess.TimeoutExpired('private-command',320)]:
            code,value=self.execute(response);self.assertEqual(code,1);self.assertEqual(value['result'],'UNVERIFIED')
        code,value=self.execute(envelope(),returncode=1);self.assertEqual(code,1)


if __name__=='__main__':unittest.main()
