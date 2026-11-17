"""One chapter's explicit official translation intent; no HTTP or renewal.

Based on MiuRead's eink_client/translation_generation request contract. A
metadata flag is never evidence that translated text has been downloaded.
Reference: c1893562aa25a870b8dd076d7be062a3348f823e, MiuRead contributors,
Copyright (C) 2026, AGPL-3.0-only. No upstream polling/retry code is copied.
"""
from copy import deepcopy
from html.parser import HTMLParser
import re
from annotation_experiment_model import digest,canonical
from verify_translation_preflight import content_summary

PROTOCOL='native-official-single-chapter-translation-v1'
MAX_RESPONSE=24*1024
HASHES={'grant_sha256','catalog_sha256','source_sha256','baseline_sha256'}
FIELDS=HASHES|{'protocol','owner','book_id','chapter_uid','book_version','translate_version'}


def fail(reason):raise ValueError('translation_generation/'+reason)


def integer(value,low=0,high=2147483647):return type(value) is int and low<=value<=high


def identity(value):return isinstance(value,str) and re.fullmatch('[1-9][0-9]{0,19}',value) is not None


def validate(plan):
    if (not isinstance(plan,dict) or set(plan)!=FIELDS or plan['protocol']!=PROTOCOL
            or not identity(plan['owner']) or not identity(plan['book_id'])
            or not integer(plan['chapter_uid'],1) or not integer(plan['book_version']) or not integer(plan['translate_version'])
            or any(not isinstance(plan[k],str) or not re.fullmatch('[a-f0-9]{64}',plan[k]) for k in HASHES)):
        fail('plan')
    return deepcopy(plan)


class Text(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.text=[];self.hidden=0;self.body=0
    def handle_starttag(self,tag,attrs):
        if tag=='body':self.body+=1
        if tag in ('script','style','head'):self.hidden+=1
    def handle_endtag(self,tag):
        if tag=='body':self.body=max(0,self.body-1)
        if tag in ('script','style','head'):self.hidden=max(0,self.hidden-1)
    def handle_data(self,value):
        if self.body and not self.hidden:self.text.append(value)


def bind(owner,grant,member,catalog,chapter,source,baseline):
    if (not identity(owner) or not isinstance(grant,dict) or grant.get('vid')!=owner
            or not isinstance(member,dict) or member.get('paying') is not True
            or not isinstance(catalog,dict) or catalog.get('format')!='epub' or not identity(catalog.get('book_id'))
            or not integer(catalog.get('version')) or not isinstance(chapter,dict)
            or not isinstance(catalog.get('chapters'),list) or sum(row==chapter for row in catalog['chapters'])!=1
            or sum(isinstance(row,dict) and row.get('uid')==chapter.get('uid') for row in catalog['chapters'])!=1
            or not integer(chapter.get('uid'),1) or chapter.get('free_or_owned') is not True
            or not integer(chapter.get('wordCount'),200,9007199254740991)
            or not isinstance(source,str) or not 200<=len(source.encode())<=2*1024*1024
            or not isinstance(baseline,dict) or not baseline):fail('admission')
    if content_summary(source)['nonempty_translation_blocks']:fail('already_available')
    text=Text();text.feed(source if re.search(r'<(?:html|body)(?:\s|>)',source,re.I) else '<body>'+source+'</body>');text.close()
    if len(''.join(text.text).strip())<100:fail('empty_original')
    version=chapter.get('translateVersion',0)
    if not integer(version):fail('version')
    return validate(dict(protocol=PROTOCOL,owner=owner,book_id=catalog['book_id'],chapter_uid=chapter['uid'],
        book_version=catalog['version'],translate_version=version,grant_sha256=digest(grant),catalog_sha256=digest(catalog),
        source_sha256=digest(source),baseline_sha256=digest(baseline)))


def generation_body(plan):
    p=validate(plan)
    return dict(bookId=p['book_id'],read=[dict(uid=p['chapter_uid'],translateVersion=p['translate_version'])],
        reference=dict(uid=p['chapter_uid'],texts=[]),freeTrial=0)


def mode_query(plan):
    p=validate(plan)
    return dict(cbid=p['book_id'],transFormat='epubTranslate',transType='epubTranslate')


def clean_response(raw):
    if not isinstance(raw,dict) or len(canonical(raw))>MAX_RESPONSE:fail('response')
    if any(k in raw and (not integer(raw[k]) or raw[k]!=0) for k in ('errcode','errCode','code')):fail('rejected')
    if 'succ' in raw and not (raw['succ'] is True or type(raw['succ']) is int and raw['succ']==1):fail('rejected')
    return raw


def response_scope(raw,plan):
    for key in ('bookId','book_id'):
        if key in raw and str(raw[key])!=plan['book_id']:fail('response_wrong_book')
    if 'vid' in raw and str(raw['vid'])!=plan['owner']:fail('response_wrong_owner')


def mode_ack(raw,plan=None):
    clean_response(raw)
    if plan is not None:response_scope(raw,validate(plan))
    if not (raw.get('succ') is True or type(raw.get('succ')) is int and raw['succ']==1):fail('mode_unconfirmed')
    return True


def status(raw,plan):
    p=validate(plan);value=clean_response(raw)
    for _ in range(4):
        response_scope(value,p)
        if any(k in value for k in ('stopPoll','curStatus','translationProgress')):break
        children=[value[k] for k in ('data','result','payload') if k in value]
        if len(children)!=1 or not isinstance(children[0],dict):fail('status_unknown')
        value=clean_response(children[0])
    else:fail('status_unknown')
    stopped=value.get('stopPoll')
    if type(stopped) is int and stopped in (0,1):stopped=bool(stopped)
    if 'stopPoll' in value and type(stopped) is not bool:fail('status_unknown')
    progress=value.get('translationProgress')
    if progress is not None and not integer(progress,0,100):fail('status_unknown')
    if stopped is None:
        if progress is None:fail('status_unknown')
        stopped=False
    rows=value.get('curStatus',[])
    if not isinstance(rows,list) or len(rows)>2:fail('status_unknown')
    seen=set();version=None
    for row in rows:
        if isinstance(row,dict):response_scope(row,p)
        if not isinstance(row,dict) or not integer(row.get('uid'),1) or row['uid'] in seen or not integer(row.get('translateVersion')):
            fail('status_unknown')
        seen.add(row['uid'])
        # This tool requests exactly one chapter, never opportunistic next work.
        if row['uid']!=p['chapter_uid']:fail('status_wrong_chapter')
        version=row['translateVersion']
        if version<p['translate_version']:fail('status_version_regressed')
    if 'tips' in value and (not isinstance(value['tips'],str) or len(value['tips'].encode())>8192):fail('status_unknown')
    if stopped and version is not None and version>0:return dict(kind='ready',version=version)
    return dict(kind='stopped_unavailable' if stopped else 'pending',version=version)


def content_verified(source):
    """A completed status cannot replace fetching actual translated text."""
    return content_summary(source)['nonempty_translation_blocks']>0
