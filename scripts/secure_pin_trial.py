"""One project-scoped pin observation; interrupted writes are never replayed."""
from contextlib import nullcontext
import json
import re
import secrets
from pathlib import Path
import tempfile

from native_shelf_trial import validate_plan
from secure_native_session import project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-pin-observation'
SERVICE_V2='org.codex.weread.goal-pin-observation-v2'
PHASES=('prepared','add_pending','add_acknowledged','add_verified','pin_pending','pin_checked',
        'unpin_pending','unpin_checked','remove_pending','restored')
RECOVERY_PHASES=('add_cleanup_pending','add_cleanup_restored','add_cleanup_timestamp_changed','add_cleanup_reading_restored')


def validate(value):
    if (not isinstance(value,dict) or set(value)!={'schema','scope','attempt','phase','plans','progress_sha256','skill_sha256'}
            or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT or value['phase'] not in PHASES+RECOVERY_PHASES
            or not isinstance(value['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
            or not isinstance(value['plans'],dict) or set(value['plans'])!={'native','web','gateway'}):
        raise StoreError('pin_trial/invalid')
    for name in ('progress_sha256','skill_sha256'):
        if not isinstance(value[name],str) or not re.fullmatch('[a-f0-9]{64}',value[name]):raise StoreError('pin_trial/invalid')
    for plan in value['plans'].values():validate_plan(plan)
    memberships=[plan['membership'] for plan in value['plans'].values()]
    if any(member!=memberships[0] for member in memberships[1:]):raise StoreError('pin_trial/mismatch')
    return value


class PinTrialStore:
    def __init__(self,backend=None,lock=None,*,service=SERVICE):
        if service not in (SERVICE,SERVICE_V2):raise StoreError('pin_trial/service')
        self.backend=backend if backend is not None else MacKeychain(service=service,account=ACCOUNT)
        suffix='-v2' if service==SERVICE_V2 else ''
        path=Path(tempfile.gettempdir())/('codex-pin-observation'+suffix+'-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=16384:raise ValueError()
            return validate(json.loads(raw)),raw
        except (ValueError,TypeError,KeyError,UnicodeError):raise StoreError('pin_trial/invalid') from None

    def read(self):
        with self.lock():return self._read()

    def pending(self):
        value,_=self.read();return value is not None and value['phase'] not in ('restored','add_cleanup_restored','add_cleanup_timestamp_changed','add_cleanup_reading_restored')

    def reserve(self,plans,progress_sha256,skill_sha256):
        with self.lock():
            if self._read()[0] is not None:raise StoreError('pin_trial/already_used')
            value=validate(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',
                plans=plans,progress_sha256=progress_sha256,skill_sha256=skill_sha256))
            raw=canonical(value);self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('pin_trial/readback')
            return value,raw

    def advance(self,raw,next_phase):
        with self.lock():
            value,current=self._read()
            if not value or not isinstance(raw,bytes) or current!=raw:raise StoreError('pin_trial/replaced')
            if value['phase'] not in PHASES:raise StoreError('pin_trial/sequence')
            index=PHASES.index(value['phase'])
            if index+1>=len(PHASES) or PHASES[index+1]!=next_phase:raise StoreError('pin_trial/sequence')
            value['phase']=next_phase;next_raw=canonical(validate(value));self.backend.save(next_raw)
            if self.backend.load()!=next_raw:raise StoreError('pin_trial/readback')
            return value,next_raw

    def cleanup(self,raw,*,verified=False,reading_only=False):
        """Claim one separate removal after add, or finish after verified readback."""
        with self.lock():
            value,current=self._read()
            if not value or not isinstance(raw,bytes) or current!=raw:raise StoreError('pin_trial/replaced')
            if type(reading_only) is not bool:raise StoreError('pin_trial/sequence')
            if value['phase']=='add_acknowledged' and verified is False and reading_only is False:phase='add_cleanup_pending'
            elif value['phase']=='add_cleanup_pending' and verified is True:
                phase='add_cleanup_reading_restored' if reading_only else 'add_cleanup_restored'
            else:raise StoreError('pin_trial/sequence')
            value['phase']=phase;next_raw=canonical(validate(value));self.backend.save(next_raw)
            if self.backend.load()!=next_raw:raise StoreError('pin_trial/readback')
            return value,next_raw

    def finish_timestamp_inspection(self,raw,*,verified=False):
        """Keep the distinct audit outcome; never label a changed timestamp restored."""
        with self.lock():
            value,current=self._read()
            if not value or not isinstance(raw,bytes) or current!=raw:raise StoreError('pin_trial/replaced')
            if value['phase']!='add_cleanup_pending' or verified is not True:raise StoreError('pin_trial/sequence')
            value['phase']='add_cleanup_timestamp_changed';next_raw=canonical(validate(value));self.backend.save(next_raw)
            if self.backend.load()!=next_raw:raise StoreError('pin_trial/readback')
            return value,next_raw
