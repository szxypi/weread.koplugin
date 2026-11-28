"""Independent immutable Keychain bundle for a future native capture.

The bundle includes the captured source, ledger and coverage evidence. This
store cannot claim, upload, close, overwrite, delete, or modify any old scope.
"""
from contextlib import nullcontext
import hashlib
import json
from pathlib import Path
import tempfile

from annotation_experiment_model import canonical
from native_time_capture import CHUNK_BYTES
from native_time_capture_evidence import validate_evidence
from readtime_upload_model import integer
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain, StoreError

SERVICE='org.codex.weread.goal-native-time-capture-bundle-v2'
MAX_BYTES=9*1024*1024
MAX_CHUNKS=(MAX_BYTES+CHUNK_BYTES-1)//CHUNK_BYTES


class CaptureBundleStore:
    def __init__(self, backend=None, *, chunks=None, lock=None, imported=False):
        if type(imported) is not bool or imported and (backend is None or chunks is None or lock is None):
            raise ValueError('capture_bundle/scope')
        self.imported=imported
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        self.chunks=chunks if chunks is not None else lambda index:MacKeychain(service=SERVICE+'.part-'+str(index),account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-time-capture-bundle-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _empty(self):
        return all(self.chunks(index).load() is None for index in range(1,MAX_CHUNKS+1))

    def _read(self):
        raw=self.backend.load()
        if raw is None:
            if not self._empty():raise StoreError('capture_bundle/orphan')
            return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=65536:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','phase','bytes','sha256','chunks'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT or value['phase']!='captured'
                    or not integer(value['bytes'],1,MAX_BYTES) or not isinstance(value['chunks'],list)
                    or len(value['chunks'])!=(value['bytes']+CHUNK_BYTES-1)//CHUNK_BYTES
                    or not isinstance(value['sha256'],str) or len(value['sha256'])!=64):raise ValueError()
            pieces=[]
            for index,part in enumerate(value['chunks'],1):
                if (not isinstance(part,dict) or set(part)!={'index','bytes','sha256'}
                        or type(part['index']) is not int or part['index']!=index
                        or not integer(part['bytes'],1,CHUNK_BYTES)
                        or index<len(value['chunks']) and part['bytes']!=CHUNK_BYTES):raise ValueError()
                data=self.chunks(index).load()
                if (not isinstance(data,bytes) or len(data)!=part['bytes']
                        or hashlib.sha256(data).hexdigest()!=part['sha256']):raise ValueError()
                pieces.append(data)
            if any(self.chunks(index).load() is not None for index in range(len(value['chunks'])+1,MAX_CHUNKS+1)):
                raise ValueError()
            content=b''.join(pieces)
            if len(content)!=value['bytes'] or hashlib.sha256(content).hexdigest()!=value['sha256']:
                raise ValueError()
            bundle=json.loads(content)
            if not isinstance(bundle,dict) or set(bundle)!={'plan','evidence'}:raise ValueError()
            validate_evidence(bundle['plan'],bundle['evidence'],imported=self.imported)
            return bundle,Receipt(raw)
        except Exception:
            raise StoreError('capture_bundle/invalid') from None

    def read(self):
        with self.lock():return self._read()

    def capture(self,plan,evidence):
        validate_evidence(plan,evidence,imported=self.imported)
        content=canonical({'plan':plan,'evidence':evidence})
        if not 0<len(content)<=MAX_BYTES:raise StoreError('capture_bundle/size')
        pieces=[content[i:i+CHUNK_BYTES] for i in range(0,len(content),CHUNK_BYTES)]
        with self.lock():
            if self._read()!=(None,None):raise StoreError('capture_bundle/consumed')
            descriptors=[]
            for index,data in enumerate(pieces,1):
                backend=self.chunks(index);backend.save(data)
                if backend.load()!=data:raise StoreError('capture_bundle/readback')
                descriptors.append({'index':index,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
            manifest=canonical({'schema':1,'scope':ACCOUNT,'phase':'captured','bytes':len(content),
                                'sha256':hashlib.sha256(content).hexdigest(),'chunks':descriptors})
            if len(manifest)>65536:raise StoreError('capture_bundle/size')
            self.backend.save(manifest)
            if self.backend.load()!=manifest:raise StoreError('capture_bundle/readback')
            value,receipt=self._read()
            if value!={'plan':plan,'evidence':evidence}:raise StoreError('capture_bundle/readback')
            return receipt
