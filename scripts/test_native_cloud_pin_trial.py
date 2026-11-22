import copy
import unittest
from native_cloud_pin_trial import bind,check,validate_plan
from secure_native_cloud_pin_trial import NativeCloudPinTrialStore
from secure_native_shelf_flag_trial import NativeFlagTrialStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_shelf_flag_change import source,point


def plan():return bind('900000','41','a'*64,source(),point())
def marked():
    value=source();value['books'][0]['isTop']=1;return value


class NativePinPlanTests(unittest.TestCase):
    def test_binds_unknown_baseline_and_positive_then_missing(self):
        p=plan();self.assertEqual(p['mark']['before'],'missing')
        self.assertTrue(check(p,marked(),point(),True));self.assertTrue(check(p,source(),point(),False))
        self.assertEqual(p['mark']['after_hash'],p['restore']['before_hash'])
        self.assertEqual(p['mark']['before_hash'],p['restore']['alternate_hash'])
    def test_other_flags_groups_and_position_are_protected(self):
        for kind in ('flag','member','group','position'):
            shelf=marked();progress=point()
            if kind=='flag':shelf['books'][1]['secret']=0
            elif kind=='member':shelf['books'].pop()
            elif kind=='group':shelf['archive'][0]['name']='changed'
            else:progress['book']['chapterOffset']+=1
            with self.subTest(kind=kind),self.assertRaises(ValueError):check(plan(),shelf,progress,True)
    def test_pin_existing_or_tampered_plan_rejected(self):
        with self.assertRaises(ValueError):bind('900000','41','a'*64,marked(),point())
        for change in (lambda p:p.update(extra=True),lambda p:p['mark'].update(desired=1),
                       lambda p:p['restore'].update(position_hash='f'*64),lambda p:p['restore'].update(book_id='42')):
            value=copy.deepcopy(plan());change(value)
            with self.assertRaises(ValueError):validate_plan(value)
    def test_distinct_persistent_intent_cannot_be_replayed(self):
        backend=Backend();store=NativeCloudPinTrialStore(backend);receipt=store.reserve(plan())
        self.assertTrue(store.pending());self.assertTrue(store.owns(receipt,plan()))
        self.assertNotEqual(store.service,NativeFlagTrialStore.service)
        with self.assertRaises(StoreError):store.reserve(plan())
        with self.assertRaises(StoreError):store.finish(receipt)
        store.finish(receipt,restored_verified=True);self.assertFalse(store.pending())
        self.assertEqual(store.read()[0]['phase'],'retired')
        with self.assertRaises(StoreError):store.reserve(plan())


if __name__=='__main__':unittest.main()
