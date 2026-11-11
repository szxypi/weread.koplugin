"""Independent new-selection preview proofs; no dispatcher or credentials I/O."""
import json
import re

from annotation_experiment_model import validate_context
from my_cloud_marks_model import identifier,integer
from selection_quote import Selection,normalized
from verify_owner_reading import FRAME,decode_envelope

FLAGS={'selection_entry','source_reference','draft_preserved','pending_preserved','original_notes_preserved',
       'reader_position_restored','anonymous_native_credentials','background_workers',
       'live_preflight','exact_body','blocked_dispatch','repeat_submit_blocked','fresh_offline_restore'}
COUNTS={'native_gets':12,'blocked_posts':1,'native_denied':32,'account_data_posts':0,'failed_line':10000}
PHASES={'init','selection','preview','commit','repeat','restore','complete'}
ERRORS={'selection_schema','selection_scope','selection_incomplete','selection_frame','selection_model','selection_input'}


def fail(reason):raise ValueError('selection_'+reason)


def reference(book,uid,index,value):
    return dict(selection=True,type=1,bookmarkId='selection:'+uid+':'+value['range']+':'+value['raw_sha256'],
                range=value['range'],chapterUid=int(uid),chapterIdx=index,markText=value['abstract'],
                source=dict(book_id=book,chapter_uid=uid,chapter_idx=index,raw_sha256=value['raw_sha256'],raw_bytes=value['raw_bytes']))


def choose(raw,marks,book,uid,index):
    """Choose one unique plain-text window disjoint from all saved ranges."""
    if not identifier(book) or not identifier(uid) or not integer(index,1000000):fail('input')
    model=Selection(raw);excluded=[]
    for row in marks.values():
        if str(row['chapterUid'])!=uid:continue
        if type(row.get('type')) is int and row['type']==0:
            from bookmark_point import point_range
            at=point_range(row.get('range'));excluded.append((at,at+1));continue
        marker=row.get('range','');match=re.fullmatch(r'([0-9]{1,10})-([0-9]{1,10})',marker)
        if not match:fail('scope')
        first,last=map(int,match.groups())
        if not 0<=first<=last<=2147483647:fail('scope')
        excluded.append((first,last))
    for at in list(range(0,len(model.flat)-39,max(8,len(model.flat)//64)))[:64]:
        stop=at+40;start,end=model.spans[at][0],model.spans[stop-1][1]
        if any(start<b and end>a for a,b in excluded):continue
        # Do not quietly substitute cross-paragraph text when a normal native
        # selection can be tested in one actual source text node.
        if '<' in model.quotes.raw[start:end]:continue
        text=model.quotes.quote(f'{start}-{end}').strip()
        pattern=normalized(text)
        first_hit=model.flat.find(pattern)
        if not text or first_hit<0 or model.flat.find(pattern,first_hit+1)>=0:continue
        first=model.filtered.starts[model.visible[at]];last=model.filtered.ends[model.visible[stop-1]]
        try:value=model.project(first,last,text)
        except ValueError:continue
        return dict(first=first,last=last,text=text,reference=reference(book,uid,index,value))
    fail('scope')


def validate_reference(row,book=None,uid=None):
    fields={'selection','type','bookmarkId','range','chapterUid','chapterIdx','markText','source'}
    if not isinstance(row,dict) or set(row)!=fields or row['selection'] is not True or type(row['type']) is not int or row['type']!=1:fail('schema')
    source=row['source']
    if (not isinstance(source,dict) or set(source)!={'book_id','chapter_uid','chapter_idx','raw_sha256','raw_bytes'}
            or not identifier(source['book_id']) or not identifier(source['chapter_uid'])
            or not integer(source['chapter_idx'],1000000) or not integer(source['raw_bytes'],2*1024*1024) or not source['raw_bytes']
            or not isinstance(source['raw_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',source['raw_sha256'])
            or not integer(row['chapterUid'],2147483647) or str(row['chapterUid'])!=source['chapter_uid']
            or not integer(row['chapterIdx'],1000000) or row['chapterIdx']!=source['chapter_idx']
            or book is not None and source['book_id']!=book or uid is not None and source['chapter_uid']!=uid):fail('scope')
    if (not isinstance(row['range'],str) or not re.fullmatch('[0-9]{1,10}-[0-9]{1,10}',row['range'])
            or not isinstance(row['markText'],str) or not 1<=len(row['markText'].encode())<=4096
            or not normalized(row['markText']) or any(ord(c)<32 and c not in '\t\r\n' for c in row['markText'])):fail('scope')
    a,b=map(int,row['range'].split('-'))
    if not 0<=a<b<=2147483647 or row['range']!=f'{a}-{b}':fail('scope')
    if row['bookmarkId']!='selection:'+source['chapter_uid']+':'+row['range']+':'+source['raw_sha256']:fail('scope')
    return row


def validate_input(payload):
    cfg=payload.get('selection_preview') if isinstance(payload,dict) else None
    if not isinstance(cfg,dict) or set(cfg)!={'credentials','first','last','reference','body'}:fail('input')
    from verify_eink_renewal import validate_credentials
    validate_credentials(cfg['credentials'])
    if cfg['credentials']['vid']!=payload['vid'] or payload.get('source_format')!='web_xhtml':fail('input')
    row=validate_reference(cfg['reference'],payload['book_id'],payload['chapter_uid'])
    if (not integer(cfg['first'],16*1024*1024) or not integer(cfg['last'],16*1024*1024) or cfg['first']>=cfg['last']
            or row['source']['raw_sha256']!=payload['source_raw_sha256']):fail('input')
    body=cfg['body']
    if not isinstance(body,dict) or set(body)!={'bookId','chapterUid','bookVersion','type','range','abstract','isPrivate','content'}:fail('input')
    validate_context({k:v for k,v in body.items() if k!='content'},payload['book_id'])
    if (body['range']!=row['range'] or body['abstract']!=row['markText'] or body['chapterUid']!=payload['chapter_uid']
            or not isinstance(body['content'],str) or not 1<=len(body['content'].encode())<=4096):fail('input')
    return cfg


def validate_stage(value,mode,complete):
    if (not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'phase'} or value['phase'] not in PHASES
            or any(type(value[k]) is not bool for k in FLAGS)
            or any(not integer(value[k],cap) for k,cap in COUNTS.items())):fail('schema')
    if not complete:return
    live=mode=='live'
    expected={k:True for k in FLAGS}
    for key in ('live_preflight','exact_body','blocked_dispatch','repeat_submit_blocked'):expected[key]=live
    expected['fresh_offline_restore']=not live
    if (any(value[k]!=expected[k] for k in FLAGS) or value['phase']!='complete' or value['failed_line'] or value['native_denied']
            or value['blocked_posts']!=int(live) or value['account_data_posts']
            or not live and value['native_gets'] or live and not 4<=value['native_gets']<=12):fail('incomplete')


def validate_private(value,complete):
    if not isinstance(value,dict) or set(value)!={'reference','body','native_text','draft_text'}:fail('schema')
    if not complete:return
    row=validate_reference(value['reference'])
    if (not isinstance(value['native_text'],str) or not 1<=len(value['native_text'].encode())<=8192
            or normalized(value['native_text'])!=normalized(row['markText'])
            or not isinstance(value['draft_text'],str) or not 1<=len(value['draft_text'].encode())<=4096):fail('scope')
    if value['body'] is not None:
        body=value['body']
        if not isinstance(body,dict) or 'content' not in body or body['content']!=value['draft_text']:fail('scope')
        validate_context({k:v for k,v in body.items() if k!='content'},row['source']['book_id'])
        if 'chapterIdx' in body or body['range']!=row['range'] or body['abstract']!=row['markText'] or body['chapterUid']!=row['source']['chapter_uid']:fail('scope')


def decode(raw,owner,*,mode=None,full_chapters=1):
    if mode not in (None,'live','reopen') or full_chapters!=1 or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:fail('frame')
    envelope=json.loads(raw.split(FRAME)[1])
    if not isinstance(envelope,dict) or set(envelope)!={'report','cookies','selection_private'}:fail('schema')
    report=envelope['report']
    if not isinstance(report,dict):fail('schema')
    stages=report.get('stages') if mode is None else [report]
    package=report.pop('installed_package',None) if mode is None else None
    if mode is None and report.get('result')=='PASS' and (not isinstance(package,dict) or set(package)!={'files','bytes_match'}
            or not integer(package['files'],1000) or not package['files'] or package['bytes_match'] is not True):fail('incomplete')
    privates=envelope['selection_private'] if mode is None else [envelope['selection_private']]
    if not isinstance(stages,list) or not isinstance(privates,list) or len(stages)!=len(privates) or len(stages)>2:fail('schema')
    addons=[]
    for stage,item in zip(stages,privates):
        if not isinstance(stage,dict):fail('schema')
        addon=stage.pop('selection_preview',None);complete=stage.get('result')=='PASS'
        validate_stage(addon,stage.get('mode'),complete);validate_private(item,complete);addons.append(addon)
        if complete and ((stage['mode']=='live')!=(item['body'] is not None)):fail('scope')
    decoded=decode_envelope(FRAME+json.dumps(dict(report=report,cookies=envelope['cookies'])).encode(),owner,
                            mode=mode,selection_preview=True)
    targets=decoded['report']['stages'] if mode is None else [decoded['report']]
    for stage,addon in zip(targets,addons):stage['selection_preview']=addon
    decoded['selection_private']=envelope['selection_private']
    if mode is None and package is not None:decoded['report']['installed_package']=package
    if mode is None and report['result']=='PASS':
        if privates[0]['reference']!=privates[1]['reference'] or privates[0]['draft_text']!=privates[1]['draft_text']:fail('model')
    return decoded


def compare(private,raw,payload):
    cfg=validate_input(payload)
    if not isinstance(private,list) or len(private)!=2:fail('model')
    for index,item in enumerate(private):
        validate_private(item,True)
        model=Selection(raw);pattern=normalized(item['native_text']);first_hit=model.flat.find(pattern)
        if first_hit<0 or model.flat.find(pattern,first_hit+1)>=0:fail('model')
        value=model.project(cfg['first'],cfg['last'],item['native_text'])
        expected=reference(payload['book_id'],payload['chapter_uid'],cfg['reference']['chapterIdx'],value)
        if expected!=cfg['reference'] or item['reference']!=expected or item['draft_text']!=cfg['body']['content']:fail('model')
        if item['body']!=(cfg['body'] if index==0 else None):fail('model')
    return True
