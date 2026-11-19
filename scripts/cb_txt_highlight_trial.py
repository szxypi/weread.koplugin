"""One plain-text highlight on a newly imported, self-authored fixture.

This is a bounded protocol experiment, not evidence of the server's visual
range interpretation and not permission to enable production TXT writes.
"""
import hashlib
import re
import tempfile
from pathlib import Path

from annotation_experiment_model import digest
from cb_fixture_highlight_trial import execute as execute_base
from secure_highlight_trial import HighlightTrialStore
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain
from verify_cb_progress import cb_id

TEXT='A unique synthetic passage for testing a plain text highlight.'
BODY=('A self-authored test begins with one emoji: 😀.\n'+TEXT+'\n'
      'The rest of this short fixture contains no personal material.\n').encode('utf-8')
PROTOCOL='cb-txt-synthetic-highlight-create-remove-v1'
SERVICE='org.codex.weread.cb-txt-highlight-intent-v1'
FIELDS={'protocol','owner_sha256','book_sha256','attempt','source_sha256','baseline_sha256','request_sha256'}


def validate_plan(value):
    if not isinstance(value,dict) or set(value)!=FIELDS or value['protocol']!=PROTOCOL:
        raise ValueError('cb_txt_highlight/plan')
    if not isinstance(value['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',value['attempt']):
        raise ValueError('cb_txt_highlight/plan')
    for key in FIELDS-{'protocol','attempt'}:
        if not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key]):
            raise ValueError('cb_txt_highlight/plan')
    return value


class Intent(HighlightTrialStore):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-cb-txt-highlight-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend,lock)

    def validate_plan(self,value):return validate_plan(value)


def prepare(owner,book,attempt,sample,version,baseline):
    if (not isinstance(owner,str) or not re.fullmatch('[1-9][0-9]{0,19}',owner)
            or not cb_id(book) or not isinstance(sample,dict) or sample.get('book_id')!=book
            or sample.get('source_format')!='web_txt' or not isinstance(sample.get('source'),str)
            or type(version) is not int or not 0<=version<=2147483647
            or not isinstance(baseline,dict) or set(baseline)!={'shelf','position','thoughts','marks'}
            or baseline['thoughts']!={} or not isinstance(baseline['marks'],dict)
            or baseline['marks'].get('updated')!={} or baseline['marks'].get('chapters')!={}):
        raise ValueError('cb_txt_highlight/scope')
    chapter=sample.get('chapter_uid');raw=sample['source'];source=raw.removeprefix('\ufeff')
    if (not isinstance(chapter,str) or not re.fullmatch('[1-9][0-9]{0,9}',chapter)
            or int(chapter)>2147483647 or source.count(TEXT)!=1 or source.count('😀')!=1
            or source.index('😀')>=source.index(TEXT) or not isinstance(sample.get('chapters'),list)
            or sum(str(row.get('chapterUid'))==chapter for row in sample['chapters'] if isinstance(row,dict))!=1):
        raise ValueError('cb_txt_highlight/source')
    start=source.index(TEXT);end=start+len(TEXT)
    if len(source[:start].encode('utf-16-le'))//2==start or source[start:end]!=TEXT:
        raise ValueError('cb_txt_highlight/source')
    sha=hashlib.sha256(raw.encode('utf-8')).hexdigest()
    if sample.get('source_raw_sha256')!=sha:raise ValueError('cb_txt_highlight/source')
    body=dict(bookId=book,chapterUid=int(chapter),bookVersion=version,type=1,style=1,colorStyle=0,
              range=f'{start}-{end}',markText=TEXT)
    plan=validate_plan(dict(protocol=PROTOCOL,owner_sha256=digest(owner),book_sha256=digest(book),attempt=attempt,
                            source_sha256=sha,baseline_sha256=digest(baseline),request_sha256=digest(body)))
    return plan,body


def execute(plan,body,baseline,intent,owned,read,send):
    return execute_base(plan,body,baseline,intent,owned,read,send,validator=validate_plan)
