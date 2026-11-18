"""Private immutable fresh-shelf baseline for later authenticated readback.

This store performs no account requests and never releases a send permission.
It is separate from the original audit and never rewrites old trial records.
"""
from contextlib import nullcontext
from copy import deepcopy
import json
from pathlib import Path
import re
import tempfile
import time

from annotation_experiment_model import canonical,digest
from native_time_bundle_accounting import audit,baseline
from native_time_bundle_evidence import FreshShelfEvidence,validate_fresh_report
from native_time_bundle_gate import binding,day
from readtime_upload_model import integer
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from verify_native_position_lua import equivalent

SERVICE='org.codex.weread.goal-native-time-fresh-audit-v1'


class FreshAuditStore:
    def __init__(self,backend=None,lock=None,*,clock=time.time):
        real=backend is None or isinstance(backend,MacKeychain) and backend.service==SERVICE
        if real and (clock is not time.time or lock is not None):raise ValueError('fresh_audit/override')
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-time-fresh-audit-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if real else nullcontext)
        self.clock=clock

    def _now(self):
        if isinstance(self.backend,MacKeychain) and self.backend.service==SERVICE and self.clock is not time.time:
            raise ValueError('fresh_audit/clock_override')
        return int(self.clock())

    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=65536:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','phase','attempt','binding_sha256','packet'}
                    or type(value['schema']) is not int or value['schema'] not in (1,2) or value['scope']!=ACCOUNT
                    or value['phase']!='baseline' or not isinstance(value['attempt'],str)
                    or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
                    or not isinstance(value['binding_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',value['binding_sha256'])
                    or not isinstance(value['packet'],dict)
                    or set(value['packet'])!=({'report','baseline','catalog_stamp','shelves','trial_scope'}
                       |({'components','components_sha256'} if value['schema']==2 else set()))):raise ValueError()
            return value,raw
        except (ValueError,TypeError,UnicodeError):raise StoreError('fresh_audit/record') from None

    def read(self):
        with self.lock():
            value,raw=self._read();return value,Receipt(raw) if raw is not None else None

    def seal(self,bundle,grant,gate,evidence,current_trial):
        if not isinstance(evidence,FreshShelfEvidence):raise ValueError('fresh_audit/evidence')
        report,snapshot,months,stamp,shelves,trial=evidence.for_bundle(bundle,grant)
        components=evidence.components_for_bundle(bundle,grant)
        if trial!=current_trial:raise ValueError('fresh_audit/trial_changed')
        original=baseline(bundle,grant,snapshot,months,report['completed_at']);now=self._now()
        if not 0<=now-report['completed_at']<30 or day(now)!=day(report['completed_at']):raise ValueError('fresh_audit/stale')
        state,receipt=gate.read()
        if not state or state['phase']!='prepared' or receipt is None or state['binding']!=binding(bundle,grant,now):
            raise ValueError('fresh_audit/gate')
        packet={'report':report,'baseline':original,'catalog_stamp':stamp,'shelves':list(shelves),'trial_scope':trial}
        if components is not None:
            packet['components']=list(components);packet['components_sha256']=digest(components)
        value={'schema':2 if components is not None else 1,'scope':ACCOUNT,'phase':'baseline','attempt':state['attempt'],
               'binding_sha256':digest(state['binding']),'packet':packet}
        raw=canonical(value)
        if len(raw)>65536:raise StoreError('fresh_audit/size')
        with self.lock():
            if self._read()!=(None,None):raise StoreError('fresh_audit/consumed')
            if (gate.read()!=(state,receipt) or evidence.for_bundle(bundle,grant)!=(report,snapshot,months,stamp,shelves,trial)
                    or evidence.components_for_bundle(bundle,grant)!=components):
                raise ValueError('fresh_audit/changed')
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('fresh_audit/readback')
            verified,token=self._read()
            if verified!=value or gate.read()!=(state,receipt):raise StoreError('fresh_audit/readback')
            return Receipt(token)

    def inspect(self,bundle,grant,gate):
        value,receipt=self.read();state,gate_receipt=gate.read()
        if (not value or not state or gate_receipt is None or state['phase'] not in ('prepared','claimed','acknowledged')
                or state['attempt']!=value['attempt'] or digest(state['binding'])!=value['binding_sha256']):
            raise ValueError('fresh_audit/gate')
        packet=value['packet'];saved=packet['baseline'];report=packet['report']
        if not isinstance(saved,dict) or not isinstance(report,dict):raise ValueError('fresh_audit/record')
        try:
            validate_fresh_report(bundle,report,saved['months'],packet['shelves'],packet['trial_scope'])
            verified=baseline(bundle,grant,saved['snapshot'],saved['months'],saved['prepared_at'])
            if (not equivalent(saved,verified) or saved['prepared_at']!=report['completed_at']
                    or not isinstance(packet['catalog_stamp'],str) or not re.fullmatch('[a-f0-9]{64}',packet['catalog_stamp'])
                    or any(state['binding'][key]!=saved[key] for key in ('bundle_sha256','owner_sha256','device_sha256'))):
                raise ValueError()
            if value['schema']==2:
                from native_time_shelf_components import validate
                components=packet['components']
                if (not isinstance(components,list) or len(components)!=2
                        or packet['components_sha256']!=digest(components)):raise ValueError()
                for component,expected in zip(components,packet['shelves']):validate(component,expected)
        except (ValueError,TypeError,KeyError):raise ValueError('fresh_audit/record') from None
        if state['phase']!='prepared' and (not integer(state['claimed_at'],saved['prepared_at'],4102444800)
                or state['claimed_at']-saved['prepared_at']>=30 or day(state['claimed_at'])!=day(saved['prepared_at'])):
            raise ValueError('fresh_audit/gate')
        return deepcopy(packet),receipt,state,gate_receipt

    def check_acknowledged(self,bundle,grant,gate,samples,trial_scope,shelf_observations):
        result=self.assess_acknowledged(bundle,grant,gate,samples,trial_scope,shelf_observations)
        if result['full_shelf_exact'] is not True:raise ValueError('fresh_shelf/changed')
        return {key:value for key,value in result.items() if key!='full_shelf_exact'}

    def assess_acknowledged(self,bundle,grant,gate,samples,trial_scope,shelf_observations):
        """Compare accounting separately, without declaring a changed full shelf safe."""
        from native_time_bundle_fresh_shelf import compare_bound
        packet,receipt,state,gate_receipt=self.inspect(bundle,grant,gate)
        if state['phase']!='acknowledged':raise ValueError('fresh_audit/no_ack')
        full_shelf_exact=True
        try:compare_bound(packet['report'],packet['shelves'],packet['trial_scope'],trial_scope,shelf_observations)
        except ValueError as error:
            if str(error)!='fresh_shelf/changed':raise
            full_shelf_exact=False
        result=audit(bundle,grant,packet['baseline'],samples,state['claimed_at'])
        result=dict(result,full_shelf_exact=full_shelf_exact)
        if not full_shelf_exact:
            result['component_diagnosis_available']=False
            if 'components' in packet:
                from cloud_group_contract import project
                from native_time_shelf_components import compare,make
                latest=tuple(make(project(shelf_observations[-1][key])) for key in ('native','web'))
                if all(value is not None for value in latest):
                    result.update(component_diagnosis_available=True,
                        native_shelf_change=compare(packet['components'][0],latest[0]),
                        web_shelf_change=compare(packet['components'][1],latest[1]))
        if self.read()[1]!=receipt or gate.read()!=(state,gate_receipt):raise ValueError('fresh_audit/changed')
        return result
