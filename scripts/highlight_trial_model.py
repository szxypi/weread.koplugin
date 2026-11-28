"""One source-bound new highlight; original annotations are never targets."""
import re
from annotation_experiment_model import digest,valid_key
from my_cloud_marks_model import identifier,integer
from selection_trial_model import validate_plan as selection_plan
from txt_coordinates import PlainSource

PROTOCOL='source-highlight-create-remove-v1'
NATIVE_PROTOCOL='native-source-highlight-create-remove-v1'
NATIVE_TXT_PROTOCOL='native-txt-highlight-create-remove-v1'
TXT_HASHES={key+'_sha256' for key in ('source','catalog','baseline','web_position','grant')}
TXT_BINDING={'protocol','owner','book_id','chapter_uid','chapter_idx','request_sha256'}|TXT_HASHES


def validate_txt_plan(value,protocol):
    if (not isinstance(value,dict) or set(value)!=TXT_BINDING or value['protocol']!=protocol
            or any(not identifier(value[key]) for key in ('owner','book_id','chapter_uid'))
            or not integer(value['chapter_idx'],1000000)
            or any(not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key])
                for key in TXT_HASHES|{'request_sha256'})):
        raise ValueError('annotation_trial/txt_plan')
    return value


def validate_plan(value,*,native=False):
    if native and isinstance(value,dict) and value.get('protocol')==NATIVE_TXT_PROTOCOL:
        return validate_txt_plan(value,NATIVE_TXT_PROTOCOL)
    if (not isinstance(value,dict) or set(value)!={'protocol','selection','request_sha256'}
            or value['protocol']!=(NATIVE_PROTOCOL if native else PROTOCOL)):raise ValueError('highlight_trial/plan')
    selection_plan(value['selection'])
    h=value['request_sha256']
    if not isinstance(h,str) or len(h)!=64 or any(c not in '0123456789abcdef' for c in h):raise ValueError('highlight_trial/plan')
    return value


def request(context):
    # Native chapterIdx is intentionally absent. Web catalog ordinals have
    # not been proven to be native chapter indices.
    return dict(bookId=context['bookId'],chapterUid=int(context['chapterUid']),bookVersion=context['bookVersion'],
                type=1,style=1,colorStyle=0,range=context['range'],markText=context['abstract'])


def bind(selection,body):
    return validate_plan(dict(protocol=PROTOCOL,selection=selection,request_sha256=digest(body)))


def bind_native(selection,body):
    value=bind(selection,body);value['protocol']=NATIVE_PROTOCOL
    return validate_plan(value,native=True)


def txt_span(marker):
    match=re.fullmatch(r'(0|[1-9][0-9]{0,9})-(0|[1-9][0-9]{0,9})',marker) if isinstance(marker,str) else None
    if match:
        start,stop=map(int,match.groups())
        if 0<=start<stop<=2147483647:return start,stop
    raise ValueError('highlight_trial/txt_range')


def txt_request(book,uid,raw,baseline):
    model=PlainSource(raw.removeprefix('\ufeff'))
    occupied=[]
    for key in ('thoughts','marks'):
        rows=baseline[key] if key=='thoughts' else baseline[key]['updated']
        for row in rows.values():
            if str(row.get('chapterUid'))==uid and (key=='thoughts' or row.get('type')!=0):
                occupied.append(txt_span(row.get('range')))
    # Use a short single-line range so it can also be selected in a narrow
    # viewport. Prefer a paragraph after the first line when one is available.
    starts=[m.end() for m in re.finditer(r'\r\n|[\r\n]',model.raw[:16384])][:32]+[0]
    for start in starts:
        line=re.split(r'[\r\n]',model.raw[start:start+512],maxsplit=1)[0]
        for offset in (0,24,48,96,160):
            quote=line[offset:offset+24].strip()
            text=''.join(quote.split())
            if len(text)<12 or '\t' in quote:continue
            index=model.flat.find(text)
            if index<0 or model.flat.find(text,index+1)>=0:continue
            first=model.starts[model.visible[index]]
            last=model.ends[model.visible[index+len(text)-1]]
            if (model.excerpt(first,len(quote))['text']==quote
                    and not any(a<last and first<b for a,b in occupied)):
                return request(dict(bookId=book,chapterUid=uid,bookVersion=0,range=f'{first}-{last}',abstract=quote))
    raise ValueError('highlight_trial/txt_selection')


def bind_txt(source,body):
    if (not isinstance(source,dict) or not isinstance(body,dict)
            or set(body)!={'bookId','chapterUid','bookVersion','type','style','colorStyle','range','markText'}
            or body['bookId']!=source.get('book_id') or type(body['chapterUid']) is not int
            or str(body['chapterUid'])!=source.get('chapter_uid')
            or any(type(body[key]) is not int or body[key]!=value for key,value in
                dict(bookVersion=0,type=1,style=1,colorStyle=0).items())
            or not isinstance(body['markText'],str) or not 0<len(body['markText'].encode())<=4096):
        raise ValueError('highlight_trial/txt_scope')
    txt_span(body['range'])
    return validate_txt_plan(dict(source,protocol=NATIVE_TXT_PROTOCOL,request_sha256=digest(body)),NATIVE_TXT_PROTOCOL)


class PendingObservation(ValueError):
    pass


def observe(baseline,current,body,*,deleted=False,target=None):
    """Protect full projected originals and match only one exact new mark."""
    if any(current[k]!=baseline[k] for k in ('shelf','position','thoughts')):raise ValueError('highlight_trial/unrelated_state')
    old,new=baseline['marks'],current['marks']
    if (any(new['updated'].get(k)!=v for k,v in old['updated'].items())
            or any(new['chapters'].get(k)!=v for k,v in old['chapters'].items())
            or not set(new['chapters']).difference(old['chapters'])<={str(body['chapterUid'])}):raise ValueError('highlight_trial/original_mark')
    added=set(new['updated'])-set(old['updated'])
    if not added:
        if deleted:return None
        raise PendingObservation('highlight_trial/not_visible')
    if len(added)!=1:raise ValueError('highlight_trial/extra_mark')
    key=next(iter(added));row=new['updated'][key]
    if (not valid_key(key) or row.get('bookmarkId')!=key
            or any(type(row.get(k)) is not int or row[k]!=body[k] for k in ('chapterUid','type','style','colorStyle'))
            or any(row.get(k)!=body[k] for k in ('range','markText'))):raise ValueError('highlight_trial/mark')
    found=dict(id=key,sha256=digest(row))
    if target is not None and found!=target:raise ValueError('highlight_trial/target_changed')
    if deleted:raise PendingObservation('highlight_trial/not_removed')
    return found
