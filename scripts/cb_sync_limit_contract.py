"""Closed CB_ local-only sync UI evidence, layered over ordinary CB reading."""
from copy import deepcopy
import json
from verify_owner_reading import decode_envelope as reading_decode,FRAME
FLAGS={'notice','local_checkpoint','unverified','pending_preserved','timer_stopped','zero_sync_requests'}


def decode_envelope(raw,owner,*,mode=None,full_chapters=1,cb_reading=False,cb_full_book=False,**extras):
    if extras or cb_reading is not True or cb_full_book is not False or full_chapters!=1:raise ValueError('cb_sync/scope')
    if not isinstance(raw,bytes) or len(raw)>4*1024*1024 or raw.count(FRAME)!=1:raise ValueError('cb_sync/frame')
    v=json.loads(raw.split(FRAME)[1]);clone=deepcopy(v)
    stages=[v['report']] if mode is not None else v['report']['stages']
    copied=[clone['report']] if mode is not None else clone['report']['stages']
    if len(stages)>2:raise ValueError('cb_sync/stages')
    for stage,copy in zip(stages,copied):
        a=stage.get('cb_sync_limit')
        if (not isinstance(a,dict) or set(a)!=FLAGS|{'native_denied','failed_line'} or any(type(a[k]) is not bool for k in FLAGS)
                or type(a['native_denied']) is not int or not 0<=a['native_denied']<=32
                or type(a['failed_line']) is not int or not 0<=a['failed_line']<=10000):raise ValueError('cb_sync/schema')
        if stage['result']=='PASS' and (not all(a[k] for k in FLAGS) or a['native_denied'] or a['failed_line']):raise ValueError('cb_sync/incomplete')
        copy.pop('cb_sync_limit')
    if mode is None:
        installed=clone['report'].pop('installed_package',None)
        if v['report']['result']=='PASS' and (not isinstance(installed,dict) or set(installed)!={'files','bytes_match'}
                or type(installed['files']) is not int or not 1<=installed['files']<=1000 or installed['bytes_match'] is not True):raise ValueError('cb_sync/installed')
    reading_decode(FRAME+json.dumps(clone).encode(),owner,mode=mode,full_chapters=1,cb_reading=True)
    return v
