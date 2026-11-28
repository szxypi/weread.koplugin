"""Full original TXT summaries with existing independent Web payload checks."""
import hashlib
import time
from fetch_weread_epub import make_read_params,sorted_query,weread_sign,weread_e
from verify_position_roundtrip import DEFAULT_TOKEN,validate_payload
from secure_shelf_experiment import canonical

PROTOCOL='txt-full-summary-same-point-v1'
HASHES={'owner_sha256','source_sha256','baseline_sha256','grant_sha256','shelf_sha256','request_sha256'}


def digest(value):return hashlib.sha256(canonical(value)).hexdigest()


def prepare(plan):
    point=plan['baseline'];summary=point['summary'];ctx=plan['context']
    if (plan['basis']!='raw_txt_utf16' or not isinstance(summary,str) or not 1<=len(summary)<=512
            or len(summary.encode())>2048 or any(ord(c)<32 and c not in '\t\r\n' for c in summary)
            or not plan['source_summary_present'] or not plan['summary_unique_start_matches']):raise ValueError('txt_full/summary')
    pc=ctx.get('pclts')
    if pc is None or str(pc) in ('','0'):pc=weread_e(int(time.time()))
    return dict(book_id=plan['book_id'],baseline=dict(point),target=None,context=ctx,pclts=pc)


def payload(plan,stage):
    if stage not in ('write_enter','write_same'):raise ValueError('txt_full/stage')
    point=plan['baseline'];ctx=plan['context']
    value=make_read_params(book_id=plan['book_id'],chapter_uid=point['chapter_uid'],chapter_idx=point['chapter_idx'],
        chapter_offset=point['chapter_offset'],progress=point['raw_percent'],summary=point['summary'],psvts=ctx['psvts'],
        pclts=plan['pclts'],token=ctx.get('token') or DEFAULT_TOKEN,elapsed_seconds=0)
    value['sm']=point['summary']
    if stage=='write_enter':
        for key in ('rt','ts','rn','sg'):value.pop(key)
    value.pop('s');value['s']=weread_sign(sorted_query(value));validate_payload(plan,stage,value)
    return value


def receipt_summary(value):
    result={'object':isinstance(value,dict)}
    if not isinstance(value,dict):return result
    for key in ('succ','status','errcode','errCode'):
        if key not in value:continue
        item=value[key];kind=type(item).__name__
        result[key+'_type']=kind if kind in ('bool','int','float','str','dict','list','NoneType') else 'other'
        if type(item) in (bool,int,float,str) and item in (0,1,'0','1'):result[key+'_known_value']=str(item)
    return result
