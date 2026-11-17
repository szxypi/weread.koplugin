"""Durable mode/generation claims. Unknown network outcomes cannot be replayed."""
from contextlib import nullcontext
from dataclasses import dataclass
import json,re,secrets,tempfile
from pathlib import Path
from annotation_experiment_model import canonical,digest
from secure_weread_session import MacKeychain,ACCOUNT,StoreError,MAX_BYTES
from secure_native_session import project_lock
from translation_generation import validate,mode_ack,MAX_RESPONSE

SERVICE='org.codex.weread.goal-official-translation-v1'


@dataclass(frozen=True,repr=False)
class Receipt:
    raw:bytes


class TranslationGenerationStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-official-translation-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=MAX_BYTES:raise ValueError()
            v=json.loads(raw)
            if (not isinstance(v,dict) or set(v)!={'schema','scope','attempt','phase','plan','requests','acks'}
                    or type(v['schema']) is not int or v['schema']!=1 or v['scope']!=ACCOUNT
                    or not isinstance(v['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',v['attempt'])
                    or not isinstance(v['requests'],list) or not isinstance(v['acks'],list)):raise ValueError()
            validate(v['plan'])
            expected={'prepared':([],[]),'mode_pending':(['mode'],[]),'mode_responded':(['mode'],['mode']),
                'generation_pending':(['mode','generation'],['mode']),
                'submitted':(['mode','generation'],['mode','generation'])}
            if v['phase'] not in expected or v['requests']!=expected[v['phase']][0]:raise ValueError()
            if [x.get('operation') for x in v['acks']]!=expected[v['phase']][1]:raise ValueError()
            for ack in v['acks']:
                if (set(ack)!={'operation','response'} or not isinstance(ack['response'],dict)
                        or len(canonical(ack['response']))>MAX_RESPONSE):raise ValueError()
            return v,raw
        except Exception:raise StoreError('translation_generation/intent_invalid') from None

    def read(self):
        with self.lock():
            v,raw=self._load();return v,Receipt(raw) if raw else None

    def _write(self,value):
        data=canonical(value)
        if len(data)>MAX_BYTES:raise StoreError('translation_generation/intent_limit')
        self.backend.save(data)
        if self.backend.load()!=data:raise StoreError('translation_generation/readback')
        self._load();return Receipt(data)

    def reserve(self,plan):
        plan=validate(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('translation_generation/consumed')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',plan=plan,requests=[],acks=[]))

    def _current(self,receipt):
        v,raw=self._load()
        if not isinstance(receipt,Receipt) or raw!=receipt.raw or v is None:raise StoreError('translation_generation/replaced')
        return v

    def claim(self,receipt,operation):
        with self.lock():
            v=self._current(receipt)
            expected={'mode':('prepared','mode_pending'),'generation':('mode_responded','generation_pending')}
            if operation not in expected or v['phase']!=expected[operation][0]:raise StoreError('translation_generation/claimed')
            if operation=='generation':mode_ack(v['acks'][0]['response'],v['plan'])
            v['requests'].append(operation);v['phase']=expected[operation][1]
            return self._write(v)

    def acknowledge(self,receipt,operation,response):
        with self.lock():
            v=self._current(receipt)
            if operation not in ('mode','generation'):raise StoreError('translation_generation/operation')
            if not isinstance(response,dict) or len(canonical(response))>MAX_RESPONSE:raise StoreError('translation_generation/response')
            if v['phase']!=operation+'_pending':raise StoreError('translation_generation/phase')
            v['acks'].append(dict(operation=operation,response=response))
            # Save the exact bounded JSON object before interpreting success.
            # An unknown receipt stays readable, but cannot grant another call.
            v['phase']='mode_responded' if operation=='mode' else 'submitted'
            return self._write(v)

    def fingerprint(self):
        value,_receipt=self.read();return digest(value)
