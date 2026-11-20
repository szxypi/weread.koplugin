"""Separate private baseline and read-only accounting for the newer capture.

The journal contains no transport or dispatch operation. A changed full shelf
can yield a partial diagnostic but never a successful full verification.
"""
from contextlib import nullcontext
from copy import deepcopy
import json
from pathlib import Path
import re
import tempfile
import time

from annotation_experiment_model import canonical,digest
from cloud_group_contract import project
from native_time_bundle_accounting import audit,baseline
from native_time_bundle_evidence import IndependentCaptureEvidence,validate_independent_report
from native_time_bundle_gate import binding,day
from native_time_independent_gate import IndependentGate
from readtime_upload_model import integer
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from txt_full_summary import digest as shelf_digest
from verify_native_position_lua import equivalent

SERVICE='org.codex.weread.goal-native-time-independent-audit-v1'
MAX_RECORD_BYTES=65536


def packet_size(packet):
    return len(canonical({'schema':2 if 'components' in packet else 1,'scope':ACCOUNT,'phase':'baseline',
                          'attempt':'0'*32,'binding_sha256':'0'*64,'packet':packet}))


class IndependentAudit:
    def __init__(self,backend=None,lock=None,*,clock=time.time):
        real=backend is None or isinstance(backend,MacKeychain)
        if real and (lock is not None or clock is not time.time):raise ValueError('independent_audit/override')
        if real and backend is not None and (backend.service!=SERVICE or backend.account!=ACCOUNT):
            raise ValueError('independent_audit/scope')
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-time-independent-audit-'+ACCOUNT+'.lock')
        self.lock=(lambda:project_lock(path)) if real else lock or nullcontext
        self.clock=clock;self._real=real;self._backend=self.backend;self._lock=self.lock

    def _now(self):
        if self._real and (self.clock is not time.time or self.backend is not self._backend or self.lock is not self._lock
                or self.backend.service!=SERVICE or self.backend.account!=ACCOUNT):raise ValueError('independent_audit/override')
        return int(self.clock())

    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=MAX_RECORD_BYTES:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','phase','attempt','binding_sha256','packet'}
                    or type(value['schema']) is not int or value['schema'] not in (1,2) or value['scope']!=ACCOUNT
                    or value['phase']!='baseline' or not isinstance(value['attempt'],str)
                    or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
                    or not isinstance(value['binding_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',value['binding_sha256'])
                    or not isinstance(value['packet'],dict)
                    or set(value['packet'])!=({'report','baseline','catalog_stamp','shelves'}
                       |({'components','components_sha256'} if value['schema']==2 else set()))):raise ValueError()
            return value,raw
        except (ValueError,TypeError,UnicodeError):raise StoreError('independent_audit/record') from None

    def read(self):
        self._now()
        with self.lock():
            value,raw=self._read();return value,Receipt(raw) if raw is not None else None

    def seal(self,bundle,grant,gate,evidence,*,include_components=True):
        if type(include_components) is not bool or not isinstance(gate,IndependentGate) or not isinstance(evidence,IndependentCaptureEvidence):
            raise ValueError('independent_audit/evidence')
        report,snapshot,months,stamp,shelves,observed=evidence.for_bundle(bundle,grant)
        components=observed if include_components else None
        original=baseline(bundle,grant,snapshot,months,report['completed_at']);now=self._now()
        if not 0<=now-report['completed_at']<30 or day(now)!=day(report['completed_at']):raise ValueError('independent_audit/stale')
        gate._capture_matches(bundle);state,receipt=gate.read()
        if not state or state['phase']!='prepared' or receipt is None or state['binding']!=binding(bundle,grant,now):
            raise ValueError('independent_audit/gate')
        packet={'report':report,'baseline':original,'catalog_stamp':stamp,'shelves':list(shelves)}
        if components is not None:
            packet['components']=list(components);packet['components_sha256']=digest(components)
        value={'schema':2 if components is not None else 1,'scope':ACCOUNT,'phase':'baseline','attempt':state['attempt'],
               'binding_sha256':digest(state['binding']),'packet':packet}
        raw=canonical(value)
        if len(raw)>MAX_RECORD_BYTES:raise StoreError('independent_audit/size')
        with self.lock():
            final=self._now()
            if not 0<=final-report['completed_at']<30 or day(final)!=day(report['completed_at']):
                raise ValueError('independent_audit/stale')
            if self._read()!=(None,None):raise StoreError('independent_audit/consumed')
            gate._capture_matches(bundle)
            if gate.read()!=(state,receipt) or evidence.for_bundle(bundle,grant)!=(report,snapshot,months,stamp,shelves,observed):
                raise ValueError('independent_audit/changed')
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('independent_audit/readback')
            verified,stored=self._read()
            if verified!=value or stored!=raw or gate.read()!=(state,receipt):raise StoreError('independent_audit/readback')
            return Receipt(stored)

    def inspect(self,bundle,grant,gate):
        if not isinstance(gate,IndependentGate):raise ValueError('independent_audit/gate')
        self._now();gate._capture_matches(bundle)
        value,receipt=self.read();state,gate_receipt=gate.read()
        if (not value or not state or gate_receipt is None or state['phase'] not in ('prepared','claimed','acknowledged')
                or state['attempt']!=value['attempt'] or digest(state['binding'])!=value['binding_sha256']):
            raise ValueError('independent_audit/gate')
        packet=value['packet'];saved=packet['baseline'];report=packet['report']
        try:
            validate_independent_report(bundle,report,saved['months'],packet['shelves'])
            verified=baseline(bundle,grant,saved['snapshot'],saved['months'],saved['prepared_at'])
            if (not equivalent(saved,verified) or saved['prepared_at']!=report['completed_at']
                    or not isinstance(packet['catalog_stamp'],str) or not re.fullmatch('[a-f0-9]{64}',packet['catalog_stamp'])
                    or any(state['binding'][key]!=saved[key] for key in ('bundle_sha256','owner_sha256','device_sha256'))):
                raise ValueError()
            if value['schema']==2:
                from native_time_shelf_components import validate
                components=packet['components']
                if (not isinstance(components,list) or len(components)!=2 or packet['components_sha256']!=digest(components)):
                    raise ValueError()
                for component,expected in zip(components,packet['shelves']):validate(component,expected)
        except (ValueError,TypeError,KeyError):raise ValueError('independent_audit/record') from None
        if state['phase']!='prepared' and (not integer(state['claimed_at'],saved['prepared_at'],4102444800)
                or state['claimed_at']-saved['prepared_at']>=30 or day(state['claimed_at'])!=day(saved['prepared_at'])):
            raise ValueError('independent_audit/gate')
        return deepcopy(packet),receipt,state,gate_receipt

    def assess_acknowledged(self,bundle,grant,gate,samples,shelf_observations):
        packet,receipt,state,gate_receipt=self.inspect(bundle,grant,gate)
        if state['phase']!='acknowledged':raise ValueError('independent_audit/no_ack')
        if not isinstance(shelf_observations,list) or len(shelf_observations)!=2:
            raise ValueError('independent_audit/shelves')
        projections=[]
        for row in shelf_observations:
            if not isinstance(row,dict) or set(row)!={'native','web'}:raise ValueError('independent_audit/shelves')
            projections.append(tuple(shelf_digest(project(row[key])) for key in ('native','web')))
        if projections[0]!=projections[1]:raise ValueError('independent_audit/unstable')
        exact=list(projections[0])==packet['shelves']
        result=dict(audit(bundle,grant,packet['baseline'],samples,state['claimed_at']),full_shelf_exact=exact)
        if not exact:
            result['result']='ACCOUNTING_PARTIAL'
            result['component_diagnosis_available']=False
            if 'components' in packet:
                from native_time_shelf_components import compare,make
                latest=tuple(make(project(shelf_observations[-1][key])) for key in ('native','web'))
                if all(value is not None for value in latest):
                    result.update(component_diagnosis_available=True,
                        native_shelf_change=compare(packet['components'][0],latest[0]),
                        web_shelf_change=compare(packet['components'][1],latest[1]))
        gate._capture_matches(bundle)
        if self.read()[1]!=receipt or gate.read()!=(state,gate_receipt):raise ValueError('independent_audit/changed')
        return result

    def check_acknowledged(self,bundle,grant,gate,samples,shelf_observations):
        result=self.assess_acknowledged(bundle,grant,gate,samples,shelf_observations)
        if result.get('result')!='ACCOUNTING_MATCH' or result.get('full_shelf_exact') is not True:
            raise ValueError('independent_audit/partial')
        return result
