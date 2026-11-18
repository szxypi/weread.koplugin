"""Only three stable, source-bound CB accounting observations can match."""
from copy import deepcopy
import unittest

from cb_native_time_bundle_accounting import audit,baseline,day
from test_cb_native_time_bundle_gate import example as captured_example
from verify_native_statistics import period


def example(*,cross_month=False,missing_day=False):
    bundle,grant,snapshot,_body,now=captured_example();plan=bundle['plan']
    if cross_month:now+=40*86400
    old=period('monthly',plan['start_time'])[0];new=period('monthly',now)[0];old_day=day(plan['start_time'])
    buckets={str(old_day):10,str(old):0}
    if missing_day:del buckets[str(old_day)]
    months={str(old):dict(baseTime=old,readTimes=buckets,totalReadTime=0 if missing_day else 10,readDays=1)}
    if new!=old:months[str(new)]=dict(baseTime=new,readTimes={},totalReadTime=0,readDays=0)
    sealed=baseline(bundle,grant,snapshot,months,now)
    after=deepcopy(snapshot);after['counts']['readingTime']+=plan['seconds']
    final=deepcopy(months);row=final[str(old)]
    row['readTimes'][str(old_day)]=row['readTimes'].get(str(old_day),0)+plan['seconds'];row['totalReadTime']+=plan['seconds']
    samples=[dict(snapshot=deepcopy(after),months=deepcopy(final),server_at=now+i) for i in range(3)]
    return bundle,grant,sealed,samples,now


class ImportedAccountingTests(unittest.TestCase):
    def test_exact_historical_delta_and_cross_month(self):
        for cross in (False,True):
            for missing in (False,True):
                bundle,grant,before,samples,now=example(cross_month=cross,missing_day=missing);original=deepcopy(before)
                result=audit(bundle,grant,before,samples,now)
                self.assertEqual(result['result'],'ACCOUNTING_MATCH');self.assertEqual(result['seconds'],6)
                self.assertEqual(result['independent_samples'],3);self.assertFalse(result['real_accounting_verified'])
                self.assertEqual(before,original)
    def test_zero_bucket_and_day_count_are_the_only_allowed_variations(self):
        bundle,grant,before,samples,now=example();month=next(iter(before['months']))
        for item in samples:del item['months'][month]['readTimes'][month];item['months'][month]['readDays']+=1
        result=audit(bundle,grant,before,samples,now)
        self.assertEqual(result['removed_zero_buckets'],1);self.assertEqual(result['read_days_delta'],1)
    def test_native_web_source_shelf_and_other_counters_must_stay_exact(self):
        for field in ('native','web','source','catalog','native_shelf','web_shelf','version','recordReadingTime','ttsTime','readingTime','float_counter'):
            bundle,grant,before,samples,now=example()
            for item in samples:
                snap=item['snapshot']
                if field in ('native','web'):snap[field]['chapter_offset']+=1
                elif field in ('source','catalog','native_shelf','web_shelf'):snap[field]='d'*64
                elif field=='version':snap[field]+=1
                elif field=='float_counter':snap['counts']['readingTime']=float(snap['counts']['readingTime'])
                else:snap['counts'][field]+=1
            with self.subTest(field=field),self.assertRaises(ValueError):audit(bundle,grant,before,samples,now)
    def test_other_dates_new_zeros_or_current_month_changes_fail(self):
        for field in ('other_bucket','new_zero','total','read_days','current_month'):
            bundle,grant,before,samples,now=example(cross_month=True)
            old=str(period('monthly',bundle['plan']['start_time'])[0]);current=str(period('monthly',now)[0])
            for item in samples:
                row=item['months'][old]
                if field=='other_bucket':row['readTimes'][old]=1
                elif field=='new_zero':row['readTimes'][str(int(old)+86400)]=0
                elif field=='total':row['totalReadTime']+=1
                elif field=='read_days':row['readDays']+=2
                else:item['months'][current]['totalReadTime']+=1
            with self.subTest(field=field),self.assertRaises(ValueError):audit(bundle,grant,before,samples,now)
    def test_samples_are_fresh_stable_three_and_bound_to_original(self):
        for mode in ('one','two','four','changed_final','backwards','early','late','bool','baseline','device','expired'):
            bundle,grant,before,samples,now=example()
            if mode=='one':samples=samples[:1]
            elif mode=='two':samples=samples[:2]
            elif mode=='four':samples.append(deepcopy(samples[-1]))
            elif mode=='changed_final':samples[-1]['snapshot']['counts']['ttsTime']=1
            elif mode=='backwards':samples[-1]['server_at']=now-1
            elif mode=='early':samples[0]['server_at']=bundle['plan']['not_before']-1
            elif mode=='late':samples[-1]['server_at']=now+181
            elif mode=='bool':samples[-1]['server_at']=True
            elif mode=='baseline':before['snapshot']['counts']['readingTime']+=1
            elif mode=='device':grant['deviceId']='eink334691225'+'2'*19
            else:now+=30
            with self.subTest(mode=mode),self.assertRaises(ValueError):audit(bundle,grant,before,samples,now)
    def test_same_device_renewal_does_not_authorize_send(self):
        bundle,grant,before,samples,now=example();grant['accessToken']='renewed-synthetic-token'
        self.assertEqual(audit(bundle,grant,before,samples,now)['result'],'ACCOUNTING_MATCH')


if __name__=='__main__':unittest.main()
