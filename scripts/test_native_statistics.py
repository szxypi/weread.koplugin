"""Synthetic statistics contracts; no account, saved grant or upstream data."""
from contextlib import redirect_stdout
from datetime import datetime
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from verify_native_statistics import CST,StatisticsError,StatisticsProbe,main,period,project,projections_equal


class StatisticsTests(unittest.TestCase):
    def setUp(self):self.now=datetime(2025,1,2,12,tzinfo=CST).timestamp();self.base=period('monthly',self.now)[0]
    def source(self,**values):return dict(baseTime=self.base,readTimes={str(self.base):60},totalReadTime=60,readDays=1,**values)

    def test_default_is_offline(self):
        with patch('verify_native_statistics.NativeSessionStore') as native,patch('verify_native_statistics.SessionStore') as web,\
                patch('verify_native_statistics.StatisticsProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        native.assert_not_called();web.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_timezone_boundaries_and_display_projection(self):
        self.assertEqual(period('monthly',datetime(2024,2,15,tzinfo=CST).timestamp())[1]-period('monthly',datetime(2024,2,15,tzinfo=CST).timestamp())[0],29*86400)
        source=self.source(secret='private',readLongest=[dict(book=dict(bookId='private-id',title='Synthetic',author='Author',token='private'),readTime=60)])
        result=project(source,'monthly',0,self.now)
        self.assertEqual(result['readLongest'],[dict(book=dict(title='Synthetic',author='Author'),readTime=60)])
        self.assertNotIn('secret',result);self.assertNotIn('bookId',result['readLongest'][0]['book'])
        self.assertEqual(result['baseTime'],self.base)

    def test_bad_required_metrics_period_and_buckets_are_not_zero(self):
        for change in ({'totalReadTime':float('nan')},{'totalReadTime':-1},{'readDays':None},{'readDays':32},{'readDays':1.5},
                       {'baseTime':self.base-86400},{'readTimes':{'bad':1}},{'readTimes':{str(self.base-86400):60}},
                       {'readTimes':{str(self.base+1):60}},{'readTimes':{str(self.base):-1}},{'errcode':-1}):
            with self.subTest(change=change),self.assertRaises(StatisticsError):project(dict(self.source(),**change),'monthly',0,self.now)
        self.assertEqual(project(dict(self.source(),readTimes={},totalReadTime=0,readDays=0),'monthly',0,self.now)['totalReadTime'],0)

    def test_optional_fields_are_bounded_and_finite(self):
        result=project(self.source(compare=float('inf'),readRate=101,preferTimeWord='bad\nvalue',preferCategoryWord='x'*8193),'monthly',0,self.now)
        for field in ('compare','readRate','preferTimeWord','preferCategoryWord'):self.assertNotIn(field,result)
        for values in ({'readLongest':{}},{'preferAuthor':[{}]*101}):
            with self.assertRaises(StatisticsError):project(self.source(**values),'monthly',0,self.now)

    def test_timestamp_units_duplicate_conflicts_and_overall_totals(self):
        result=project(dict(self.source(),readTimes={str(self.base*1000):60,str(self.base):60}),'monthly',0,self.now)
        self.assertEqual(result['readTimes'],{str(self.base):60})
        with self.assertRaises(StatisticsError):project(dict(self.source(),readTimes={str(self.base*1000):61,str(self.base):60}),'monthly',0,self.now)
        result=project(dict(baseTime=0,readTimes={str(self.base):60},totalReadTime=120,readDays=1),'overall',0,self.now)
        self.assertEqual(result['totalReadTime'],120)

    def test_only_known_get_queries(self):
        probe=StatisticsProbe()
        probe.guard('statistics_monthly','https://i.weread.qq.com/readdata/detail?mode=monthly&baseTime=0',None)
        for url,body in (('https://evil.invalid/readdata/detail?mode=monthly&baseTime=0',None),
                         ('https://i.weread.qq.com/readdata/detail?mode=other&baseTime=0',None),
                         ('https://i.weread.qq.com/readdata/detail?mode=monthly&baseTime=0&baseTime=0',None),
                         ('https://i.weread.qq.com/readdata/detail?mode=monthly&baseTime=-1',None),
                         ('https://i.weread.qq.com/readdata/detail?mode=monthly&baseTime=0',{})):
            with self.assertRaises(StatisticsError):probe.guard('statistics_monthly',url,body)

    def test_json_float_tolerance_does_not_hide_changed_seconds(self):
        self.assertTrue(projections_equal({'compare':1.12345678901234},{'compare':1.12345678901235}))
        self.assertFalse(projections_equal({'totalReadTime':60},{'totalReadTime':61}))
        self.assertFalse(projections_equal(False,0))

    def test_private_child_failure_and_credentials_never_enter_report(self):
        credentials=dict(vid='88008800',accessToken='private-access')
        sample=dict(mode='monthly',source=dict(title='private-title'),expected={})
        probe=SimpleNamespace(samples=[sample],inspect=lambda _:dict(responses=[]),report=dict(stages=[]))
        with patch('verify_native_statistics.SessionStore') as web,patch('verify_native_statistics.NativeSessionStore') as native,\
                patch('verify_native_statistics.StatisticsProbe',return_value=probe),\
                patch('verify_native_statistics.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout=b'private-output')),redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='88008800');native.return_value.load.return_value=credentials
            self.assertEqual(main(['--saved-session','--native-http','--lua-command','synthetic']),1)
        for private in ('88008800','private-access','private-title','private-output'):self.assertNotIn(private,out.getvalue())
        self.assertEqual(credentials,{})


if __name__=='__main__':unittest.main()
