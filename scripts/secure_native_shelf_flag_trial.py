"""Native two-slot intent. Completed tombstones remain and cannot be replayed."""
import json
import secrets
from native_shelf_flag_trial import validate_plan
from secure_native_shelf_trial import NativeShelfTrialStore
from secure_shelf_experiment import canonical,Receipt
from secure_weread_session import ACCOUNT,StoreError


class NativeFlagTrialStore(NativeShelfTrialStore):
    service='org.codex.weread.goal-native-private-flag-trial-v1'
    lock_prefix='codex-native-private-flag-'
    validator=staticmethod(validate_plan)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            value=json.loads(raw)
            if (not isinstance(raw,bytes) or not 0<len(raw)<=8192 or not isinstance(value,dict)
                    or set(value)!={'schema','scope','attempt','reserved_posts','plan','phase'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or type(value['reserved_posts']) is not int or value['reserved_posts']!=2
                    or value['phase'] not in ('possible_dispatch','retired') or not isinstance(value['attempt'],str)
                    or len(value['attempt'])!=32 or any(c not in 'abcdef0123456789' for c in value['attempt'])):raise ValueError()
            self.validator(value['plan']);return value,raw
        except (ValueError,TypeError,KeyError,UnicodeError):raise StoreError('native_shelf_flag/intent_invalid') from None

    def pending(self):
        value,_raw=self.read();return value is not None and value['phase']!='retired'

    def _write(self,value):
        raw=canonical(value);self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('native_shelf_flag/readback')
        self._load();return Receipt(raw)

    def reserve(self,plan):
        self.validator(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('native_shelf_flag/already_reserved')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),reserved_posts=2,plan=plan,phase='possible_dispatch'))

    def owns(self,receipt,plan):
        return self.pending() and super().owns(receipt,plan)

    def finish(self,receipt,*,restored_verified=False):
        if restored_verified is not True:raise StoreError('native_shelf_flag/proof')
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.pending or value['phase']!='possible_dispatch':raise StoreError('native_shelf_flag/replaced')
            value['phase']='retired';self._write(value)
