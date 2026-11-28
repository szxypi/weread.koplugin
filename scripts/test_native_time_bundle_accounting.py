"""Only exact stable historical accounting may match the sealed baseline."""
from copy import deepcopy
import unittest

from native_time_bundle_accounting import audit,baseline,day
from test_native_time_bundle_gate import fixture
from txt_full_summary import digest as captured_digest
from verify_native_statistics import period


def example(*,cross_month=False,missing_day=False):
    bundle,grant,_body,now=fixture();p=bundle['plan']
    if cross_month:now+=40*86400
    point=dict(chapter_uid=int(p['chapter_uid']),chapter_idx=p['chapter_idx'],chapter_offset=12,
               raw_percent=3,summary={'present':False},chapterTitle={'present':False})
    snapshot=dict(point=point,web_point=deepcopy(point),counts=dict(readingTime=20,recordReadingTime=0,ttsTime=0),
                  version=p['book_version'],shelf='a'*64,source=p['raw_sha256'],catalog='b'*64)
    p['baseline_sha256']=captured_digest(snapshot)
    old_month=period('monthly',p['start_time'])[0];new_month=period('monthly',now)[0];old_day=day(p['start_time'])
    buckets={str(old_day):10,str(old_month):0}
    if missing_day:del buckets[str(old_day)]
    old_total=0 if missing_day else 10
    months={str(old_month):dict(baseTime=old_month,readTimes=buckets,totalReadTime=old_total,readDays=1)}
    if new_month!=old_month:months[str(new_month)]=dict(baseTime=new_month,readTimes={},totalReadTime=0,readDays=0)
    sealed=baseline(bundle,grant,snapshot,months,now)
    after=deepcopy(snapshot);after['counts']['readingTime']+=p['seconds']
    after_months=deepcopy(months);row=after_months[str(old_month)]
    row['readTimes'][str(old_day)]=row['readTimes'].get(str(old_day),0)+p['seconds'];row['totalReadTime']+=p['seconds']
    samples=[dict(snapshot=deepcopy(after),months=deepcopy(after_months),server_at=now+i) for i in range(3)]
    return bundle,grant,sealed,samples,now


class BundleAccountingTests(unittest.TestCase):
    def test_exact_historical_delta_and_two_stable_reads_plus_final(self):
        for cross in (False,True):
            for missing in (False,True):
                bundle,grant,before,samples,now=example(cross_month=cross,missing_day=missing)
                original=deepcopy(before);result=audit(bundle,grant,before,samples,now)
                self.assertEqual(result['result'],'ACCOUNTING_MATCH');self.assertEqual(result['seconds'],6)
                self.assertEqual(result['independent_samples'],3);self.assertFalse(result['real_accounting_verified'])
                self.assertEqual(before,original)

    def test_zero_bucket_removal_and_read_days_delta_are_only_allowed_variations(self):
        bundle,grant,before,samples,now=example();month=next(iter(before['months']))
        for item in samples:
            del item['months'][month]['readTimes'][month]
            item['months'][month]['readDays']+=1
        result=audit(bundle,grant,before,samples,now)
        self.assertEqual(result['removed_zero_buckets'],1);self.assertEqual(result['read_days_delta'],1)

    def test_position_source_shelf_and_all_other_counts_must_remain_exact(self):
        for field in ('point','web_point','source','catalog','shelf','version','recordReadingTime','ttsTime','readingTime','float_counter'):
            bundle,grant,before,samples,now=example()
            for item in samples:
                snap=item['snapshot']
                if field in ('point','web_point'):snap[field]['chapter_offset']+=1
                elif field in ('source','catalog','shelf'):snap[field]='c'*64
                elif field=='version':snap[field]+=1
                elif field=='float_counter':snap['counts']['readingTime']=float(snap['counts']['readingTime'])
                else:snap['counts'][field]+=1
            with self.subTest(field=field),self.assertRaises(ValueError):audit(bundle,grant,before,samples,now)

    def test_other_days_current_month_or_added_zero_must_not_change(self):
        for field in ('other_bucket','new_zero','total','read_days','current_month'):
            bundle,grant,before,samples,now=example(cross_month=True);old=str(period('monthly',bundle['plan']['start_time'])[0]);current=str(period('monthly',now)[0])
            for item in samples:
                row=item['months'][old]
                if field=='other_bucket':row['readTimes'][old]=1
                elif field=='new_zero':row['readTimes'][str(int(old)+86400)]=0
                elif field=='total':row['totalReadTime']+=1
                elif field=='read_days':row['readDays']+=2
                else:item['months'][current]['totalReadTime']+=1
            with self.subTest(field=field),self.assertRaises(ValueError):audit(bundle,grant,before,samples,now)

    def test_samples_must_be_stable_fresh_and_three_independent_inputs(self):
        for mode in ('one','two','four','changed_final','backwards','early','late','bool'):
            bundle,grant,before,samples,now=example()
            if mode=='one':samples=samples[:1]
            elif mode=='two':samples=samples[:2]
            elif mode=='four':samples.append(deepcopy(samples[-1]))
            elif mode=='changed_final':samples[-1]['snapshot']['counts']['ttsTime']=1
            elif mode=='backwards':samples[-1]['server_at']=now-1
            elif mode=='early':samples[0]['server_at']=bundle['plan']['not_before']-1
            elif mode=='late':samples[-1]['server_at']=now+181
            else:samples[-1]['server_at']=True
            with self.subTest(mode=mode),self.assertRaises(ValueError):audit(bundle,grant,before,samples,now)


    def test_same_device_renewal_can_recheck_without_releasing_a_send(self):
        bundle,grant,before,samples,now=example();grant['accessToken']='renewed-synthetic-token'
        self.assertEqual(audit(bundle,grant,before,samples,now)['result'],'ACCOUNTING_MATCH')

    def test_corrupt_baseline_or_dispatch_boundary_is_never_reconstructed(self):
        for mode in ('baseline','source','owner','device','expired','future','other_day'):
            bundle,grant,before,samples,now=example()
            if mode=='baseline':before['snapshot']['counts']['readingTime']+=1
            elif mode=='source':bundle['plan']['raw_sha256']='f'*64
            elif mode=='owner':grant['vid']='900001'
            elif mode=='device':grant['deviceId']='eink334691225'+'2'*19
            elif mode=='expired':now+=30
            elif mode=='future':now-=1
            else:now+=86400
            with self.subTest(mode=mode),self.assertRaises(ValueError):audit(bundle,grant,before,samples,now)


if __name__=='__main__':unittest.main()
