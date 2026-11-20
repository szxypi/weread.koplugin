#!/usr/bin/env python3
"""Read-only reconciliation of one pending private-thought experiment.

Never edits the journal or sends POSTs. Only fixed type/equality/status fields
leave memory; no record IDs, source text, nonce or credentials are printed.
"""
import argparse
from datetime import datetime,timezone
import json
import re
import time
from urllib.parse import urlencode

from annotation_experiment_model import context,digest,note_text,shelf_state,thoughts_state,marks_state,point
from secure_annotation_experiment import AnnotationExperimentStore
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import NativeProbe,BASE
from verify_annotation_experiment import query


class Inspector(NativeProbe):
    def __init__(self,book,opener=None):
        super().__init__(opener);self.book=book;self.last=0;self.calls=0

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed={'shelf':BASE+'/shelf/sync','thoughts':query(self.book),
            'marks':BASE+'/book/bookmarklist?'+urlencode(dict(bookId=self.book,synckey=0)),
            'metadata':BASE+'/book/info?'+urlencode(dict(bookId=self.book)),
            'position':BASE+'/book/getProgress?'+urlencode(dict(bookId=self.book))}
        if body is not None or stage not in allowed or url!=allowed[stage] or self.calls>=5:raise ValueError('annotation_inspection/request')
        self.calls+=1
        delay=.35-(time.monotonic()-self.last)
        if delay>0:time.sleep(delay)
        self.last=time.monotonic();return super().request(stage,url,credentials=credentials,timeout=timeout)


def inspect(sources,plan):
    book,owner=plan['book_id'],plan['owner']
    report={}
    for name,convert in [('shelf',shelf_state),('marks',lambda source:marks_state(source,book,owner)),('position',lambda source:point(source,book))]:
        report['original_'+name+'_unchanged']=digest(convert(sources[name]))==plan[name+'_sha256']
    _mark,ctx=context(sources['marks'],sources['metadata'],book,owner,plan['bookmark_id'])
    report['original_context_unchanged']=digest(ctx)==plan['context_sha256']
    raw=sources['thoughts'];rows=raw.get('reviews')
    if not isinstance(rows,list) or len(rows)>20:raise ValueError('annotation_inspection/rows')
    tests=[];original=[]
    for wrapper in rows:
        review=wrapper.get('review',wrapper) if isinstance(wrapper,dict) else None
        if not isinstance(review,dict):raise ValueError('annotation_inspection/row')
        if review.get('content') in (note_text(plan['nonce']),note_text(plan['nonce'],True)):tests.append((wrapper,review))
        else:original.append(wrapper)
    report['matching_test_records']=len(tests)
    remaining=dict(raw,reviews=original,totalCount=len(original),hasMore=0)
    report['original_thoughts_unchanged']=digest(thoughts_state(remaining,book,owner))==plan['thoughts_sha256']
    try:thoughts_state(raw,book,owner);report['full_projection_valid']=True
    except ValueError as error:
        report['full_projection_valid']=False
        report['projection_reason']=str(error) if re.fullmatch('my_thoughts_[a-z_]+',str(error)) else 'unrecognized_projection'
    if len(tests)==1:
        wrapper,row=tests[0]
        known=['reviewId','bookId','userVid','chapterUid','chapterIdx','range','content','abstract','type','isPrivate','createTime','updateTime','finishReading']
        report['test_field_types']={key:'null' if row[key] is None else type(row[key]).__name__ for key in known if key in row}
        report['test_unknown_fields_count']=len(set(row)-set(known))
        private=row.get('isPrivate')
        report['test_private']=bool(private) if type(private) in (int,bool) and private in (0,1) else None
        report['test_id_consistent']=isinstance(row.get('reviewId'),str) and wrapper.get('reviewId',row['reviewId'])==row['reviewId']
        report['test_same_book']=str(row.get('bookId'))==book;report['test_same_owner']=str(row.get('userVid'))==owner
        report['test_initial_text']=row.get('content')==note_text(plan['nonce']);report['test_edited_text']=row.get('content')==note_text(plan['nonce'],True)
        report['test_context_checks']={key:row.get(key)==ctx[key] for key in ('type','range','abstract')}
        report['test_context_checks']['chapterUid']=str(row.get('chapterUid'))==ctx['chapterUid']
        if 'chapterIdx' in ctx:report['test_context_checks']['chapterIdx']=row.get('chapterIdx')==ctx['chapterIdx']
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),data_posts=0,authentication_posts=0,journal_modified=False,private_values_saved_to_files=False)
    credentials=probe=None
    try:
        if args.saved_session:
            pending,_receipt=AnnotationExperimentStore().read()
            if not pending:raise ValueError('annotation_inspection/no_intent')
            plan=pending['plan'];credentials=NativeSessionStore().load(SessionStore().load()['vid'])
            if credentials['vid']!=plan['owner']:raise ValueError('annotation_inspection/owner')
            report.update(intent_phase=pending['phase'],posts_consumed=pending['posts'])
            probe=Inspector(plan['book_id']);sources={}
            for stage,url in [('shelf',BASE+'/shelf/sync'),('marks',BASE+'/book/bookmarklist?'+urlencode(dict(bookId=plan['book_id'],synckey=0))),
                ('metadata',BASE+'/book/info?'+urlencode(dict(bookId=plan['book_id']))),('position',BASE+'/book/getProgress?'+urlencode(dict(bookId=plan['book_id']))),('thoughts',query(plan['book_id']))]:
                sources[stage]=probe.request(stage,url,credentials=credentials)
            report.update(inspect(sources,plan),result='ANNOTATION_PENDING_READ_ONLY_INSPECTED')
    except Exception:report.update(result='UNVERIFIED',reason='annotation_inspection_failed')
    finally:
        if probe:report['stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in probe.report['stages']]
        if credentials:credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
