"""Duration equality must not erase presence changes or accept new buckets."""
from copy import deepcopy
import unittest
from unittest.mock import patch
from annotation_experiment_model import digest
from cross_day_trial import day,expected_months
from selection_trial_mock import credentials
from test_readtime_cross_day_upload import fixture
import readtime_statistics as stats


def sample():
    t,_source,_op,_clock,*_rest=fixture()
    with patch('verify_readtime_cross_day_upload.local_zone',return_value='+08:00'),patch('verify_readtime_cross_day.reading_position',return_value=t.source.plan.web_position):
        t.prepare({'vid':t.capture.read()[0]['plan']['source']['owner']},credentials())
    before=deepcopy(t.stats);month=next(iter(before));start=int(month)
    # Deliberately use days distinct from both controlled target and current day.
    target=str(day(t.bound['capture']['start_time']));today=str(day(t.bound['created_at']))
    zero_days=[str(start+i*86400) for i in range(10) if str(start+i*86400) not in (target,today)]
    for key in zero_days[:2]:before[month]['readTimes'][key]=0
    plan=deepcopy(t.bound);plan['statistics_sha256']=digest(before)
    after=expected_months(before,plan['capture'],plan['created_at'])[0]
    return plan,before,after,zero_days[:2]


class StatisticsTests(unittest.TestCase):
    def test_exact_or_removed_zeros_are_distinct_audited_results_without_mutation(self):
        p,b,a,zero=sample();old=deepcopy((b,a));m=next(iter(b))
        self.assertEqual(stats.match(b,a,p['capture'],p['created_at']),dict(removed_zero_buckets=0,read_days_delta=0))
        self.assertEqual((b,a),old)
        del a[m]['readTimes'][zero[0]]
        self.assertEqual(stats.match(b,a,p['capture'],p['created_at']),dict(removed_zero_buckets=1,read_days_delta=0))
        del a[m]['readTimes'][zero[1]]
        self.assertEqual(stats.match(b,a,p['capture'],p['created_at']),dict(removed_zero_buckets=2,read_days_delta=0))

    def test_new_zero_missing_positive_and_any_extra_seconds_are_rejected(self):
        p,b,after,zero=sample();m=next(iter(b));target=str(day(p['capture']['start_time']))
        for kind in ('new_zero','positive_missing','extra','changed_zero','total','readDays','current_day'):
            a=deepcopy(after)
            if kind=='new_zero':a[m]['readTimes'][str(int(m)+25*86400)]=0
            elif kind=='positive_missing':del a[m]['readTimes'][target]
            elif kind=='extra':a[m]['readTimes'][target]+=1
            elif kind=='changed_zero':a[m]['readTimes'][zero[0]]=1
            elif kind=='total':a[m]['totalReadTime']+=1
            elif kind=='readDays':a[m]['readDays']+=2
            else:
                a[m]['readTimes'][target]-=2;a[m]['readTimes'][str(day(p['created_at']))]=2
            with self.subTest(kind=kind):self.assertIsNone(stats.match(b,a,p['capture'],p['created_at']))

    def test_exact_sealed_baseline_reconstruction_keeps_all_nonzero_values(self):
        p,b,a,zero=sample();m=next(iter(b))
        for k in zero:del a[m]['readTimes'][k]
        original=deepcopy((p,a));rebuilt,audit=stats.reconstruct(p,a)
        self.assertEqual(rebuilt,b);self.assertEqual(audit,dict(removed_zero_buckets=2,read_days_delta=0,baseline_digest_exact=True))
        self.assertEqual((p,a),original);self.assertEqual(digest(rebuilt),p['statistics_sha256'])

    def test_digest_mismatch_new_zero_extra_seconds_or_three_removals_never_reconstruct(self):
        p,b,original,zero=sample();m=next(iter(b))
        for kind in ('digest','new_zero','extra','third_zero'):
            plan=deepcopy(p);a=deepcopy(original)
            if kind=='digest':plan['statistics_sha256']='a'*64
            elif kind=='new_zero':a[m]['readTimes'][str(int(m)+25*86400)]=0
            elif kind=='extra':a[m]['readTimes'][str(day(p['capture']['start_time']))]+=1
            else:
                before=deepcopy(b);before[m]['readTimes'][str(int(m)+24*86400)]=0;plan['statistics_sha256']=digest(before)
                for key in zero:del a[m]['readTimes'][key]
            with self.subTest(kind=kind):self.assertIsNone(stats.reconstruct(plan,a))

    def test_absent_historical_bucket_can_be_recovered_without_inventing_old_zero(self):
        p,b,_a,_zero=sample();m=next(iter(b));target=str(day(p['capture']['start_time']))
        del b[m]['readTimes'][target];p['statistics_sha256']=digest(b)
        a=expected_months(b,p['capture'],p['created_at'])[0];rebuilt,_audit=stats.reconstruct(p,a)
        self.assertEqual(rebuilt,b);self.assertNotIn(target,rebuilt[m]['readTimes'])

    def test_one_qualifying_read_day_is_explicit_and_two_is_rejected(self):
        p,b,a,_zero=sample();m=next(iter(b));a[m]['readDays']+=1
        self.assertEqual(stats.match(b,a,p['capture'],p['created_at'])['read_days_delta'],1)
        self.assertEqual(stats.reconstruct(p,a)[0],b)
        a[m]['readDays']+=1;self.assertIsNone(stats.match(b,a,p['capture'],p['created_at']))

    def test_malformed_fields_alias_keys_booleans_unaligned_and_nonfinite_fail(self):
        _p,b,_a,zero=sample();m=next(iter(b))
        for kind in ('extra','bool','alias','unaligned','nan','foreign_month','negative'):
            value=deepcopy(b)
            if kind=='extra':value[m]['title']='private'
            elif kind=='bool':value[m]['readTimes'][zero[0]]=False
            elif kind=='alias':value[m]['readTimes']['0'+zero[0]]=value[m]['readTimes'].pop(zero[0])
            elif kind=='unaligned':value[m]['readTimes'][str(int(zero[0])+1)]=0
            elif kind=='nan':value[m]['totalReadTime']=float('nan')
            elif kind=='negative':value[m]['readTimes'][zero[0]]=-1
            else:value['foreign']=value.pop(m)
            with self.subTest(kind=kind),self.assertRaises(ValueError):stats.validate(value)

    def test_unchanged_current_month_is_still_required_for_cross_month_batch(self):
        p,b,_a,_zero=sample();p['created_at']+=40*86400
        current=str(stats.period('monthly',p['created_at'])[0]);b[current]=dict(baseTime=int(current),readTimes={},totalReadTime=0,readDays=0)
        p['statistics_sha256']=digest(b);a=expected_months(b,p['capture'],p['created_at'])[0]
        self.assertIsNotNone(stats.match(b,a,p['capture'],p['created_at']))
        self.assertEqual(stats.reconstruct(p,a)[0],b)
        a[current]['totalReadTime']=2;self.assertIsNone(stats.match(b,a,p['capture'],p['created_at']))


if __name__=='__main__':unittest.main()
