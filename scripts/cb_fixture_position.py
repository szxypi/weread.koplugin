"""Pure one-shot position plan for a newly uploaded self-authored CB book.

This module has no network client. It binds all possible positions and a
long, non-private test summary to the exact uploaded fixture and source.
"""
import hashlib
import json
import time
import unicodedata
from fetch_weread_epub import make_read_params,sorted_query,web_app_id,weread_e,weread_sign
from synthetic_upload_epub import TEXT
from verify_cb_progress import cb_id
from verify_source_coordinates import FilteredSource
from verify_position_roundtrip import DEFAULT_TOKEN
from verify_reader_progress import project as project_progress

LONG_SUMMARY='Synthetic fixture long summary to check exact server retention beyond twenty characters.'
STAGES=('enter','same','probe','restore')


def plan(book,sample,*,require_unstarted=True):
    if not cb_id(book) or not isinstance(sample,dict) or sample.get('book_id')!=book or sample.get('source_format')!='web_xhtml':
        raise ValueError('fixture_position/scope')
    if require_unstarted and sample.get('baseline')!=dict(chapter='0',offset=0,percent=0):
        raise ValueError('fixture_position/already_started')
    source=sample.get('source');chapter=sample.get('chapter_uid');context=sample.get('context');rows=sample.get('chapters')
    if not isinstance(source,str) or TEXT not in source or not isinstance(chapter,str) or not chapter.isdigit() or not isinstance(rows,list):
        raise ValueError('fixture_position/source')
    selected=[row for row in rows if str(row.get('chapterUid'))==chapter]
    if len(selected)!=1 or not isinstance(context,dict) or context.get('book_id')!=book or not context.get('psvts'):
        raise ValueError('fixture_position/context')
    if require_unstarted:
        embedded=project_progress(context.get('progress'),book)
        if (str(embedded.get('chapter_uid'))!='0' or not embedded['has_chapter_offset']
                or embedded['chapter_offset']!=0 or embedded['raw_percent']!=0):
            raise ValueError('fixture_position/context_changed')
    index=selected[0].get('chapterIdx')
    if type(index) is not int or not 0<=index<=1000000:raise ValueError('fixture_position/index')
    model=FilteredSource(source,allow_multiple_bodies=True)
    first=model.locate(TEXT)[0];indexes=[i for i,value in enumerate(model.starts) if value==first]
    if len(indexes)!=1 or indexes[0]+1>=len(model.starts):raise ValueError('fixture_position/boundary')
    i=indexes[0];following=model.starts[i+1]
    if following!=first+1 or model.ends[i]!=following or any(
            char.isspace() or unicodedata.category(char)[0] in ('M','C') for char in model.characters[i:i+2]):
        raise ValueError('fixture_position/boundary')
    model.anchor_at(first);model.anchor_at(following)
    pc=context.get('pclts')
    if pc is None or str(pc) in ('','0'):pc=weread_e(int(time.time()))
    return dict(book=book,chapter=chapter,index=index,first=first,following=following,percent=1,
                psvts=context['psvts'],pclts=pc,token=context.get('token') or DEFAULT_TOKEN)


def body(plan,stage,*,now=None):
    if stage not in STAGES:raise ValueError('fixture_position/stage')
    position=plan['following'] if stage=='probe' else plan['first']
    value=make_read_params(book_id=plan['book'],chapter_uid=plan['chapter'],chapter_idx=plan['index'],chapter_offset=position,
        progress=plan['percent'],summary=LONG_SUMMARY,psvts=plan['psvts'],pclts=plan['pclts'],token=plan['token'],elapsed_seconds=0)
    if stage=='enter':
        for key in ('rt','ts','rn','sg'):value.pop(key)
    value['sm']=LONG_SUMMARY
    value['s']=weread_sign(sorted_query({k:v for k,v in value.items() if k!='s'}))
    validate(plan,stage,value,now=now)
    return value


def validate(plan,stage,value,*,now=None):
    now=int(time.time()) if now is None else now
    if stage not in STAGES or not isinstance(value,dict) or type(now) is not int:raise ValueError('fixture_position/body')
    keys={'appId','b','c','ci','co','sm','pr','ct','ps','pc','s'}
    if stage!='enter':keys|={'rt','ts','rn','sg'}
    expected=plan['following'] if stage=='probe' else plan['first']
    if (set(value)!=keys or not cb_id(plan['book']) or value['appId']!=web_app_id() or value['b']!=weread_e(plan['book'])
            or value['c']!=weread_e(plan['chapter']) or type(value['ci']) is not int or value['ci']!=plan['index']
            or type(value['co']) is not int or value['co']!=expected or value['sm']!=LONG_SUMMARY
            or value['pr']!=1 or type(value['pr']) is not int or value['ps']!=plan['psvts'] or value['pc']!=plan['pclts']
            or type(value['ct']) is not int or not 0<=now-value['ct']<=30
            or value['s']!=weread_sign(sorted_query({k:v for k,v in value.items() if k!='s'}))):
        raise ValueError('fixture_position/body')
    if stage!='enter' and (value['rt']!=0 or type(value['rt']) is not int or type(value['ts']) is not int
            or value['ts']//1000!=value['ct'] or type(value['rn']) is not int or not 0<=value['rn']<=999
            or value['sg']!=hashlib.sha256(f"{value['ts']}{value['rn']}{plan['token']}".encode()).hexdigest()):
        raise ValueError('fixture_position/body')
    return True


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)
