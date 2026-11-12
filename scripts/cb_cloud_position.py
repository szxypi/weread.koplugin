"""Read-only CB_ coordinates. No candidate, persistence, or dispatch authority."""
import re
from source_remote_position import resolve
from verify_reader_progress import project,find_node,ProgressError
from verify_source_coordinates import FilteredSource,CoordinateError

REASONS={'progress_invalid','progress_book_mismatch','progress_rejected','progress_not_found','progress_ambiguous','progress_no_chapter','progress_source_incomplete'}


def state(raw,book,chapters,channel):
    if not isinstance(book,str) or not re.fullmatch(r'CB_[A-Za-z0-9]{1,64}',book) or channel not in ('web','native'):raise ValueError('cb_cloud/scope')
    try:
        p=resolve(raw,book,chapters,channel);node=find_node(raw,book)
        return dict(kind='located',book_id=book,chapter_uid=str(p['chapter_uid']),chapter_idx=p['chapter_idx'],chapter_offset=p['chapter_offset'],
                    raw_percent=p['raw_percent'],summary=p['summary'],index_source=p['chapter_index_source'],summary_present='summary' in node)
    except ProgressError as error:
        reason=str(error) if str(error) in REASONS else 'progress_invalid'
        return dict(kind='no_chapter' if reason=='progress_no_chapter' else 'unavailable',reason=reason)


def observed(raw,book,chapters,channel):
    value=state(raw,book,chapters,channel)
    # Include raw-field presence to detect changes without inventing zeros.
    try:p=project(raw,book,channel);node=find_node(raw,book)
    except ProgressError:return dict(state=value,presence={},projection={},counters={})
    return dict(state=value,presence=dict(index=any(k in node for k in ('chapterIdx','chapterIndex','chapter_idx')),
                summary=any(k in node for k in ('summary','chapterTitle')),offset=p['has_chapter_offset'],uid=p['chapter_uid'] is not None),
                projection={k:p[k] for k in ('chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')},
                counters={k:dict(present=k in node,value=node.get(k)) for k in ('readingTime','recordReadingTime','ttsTime')})


def mapping(source,source_uid,point):
    r=dict(chapter_matches=False,visible_boundary=False,unique_anchor=False,summary_present=False,summary_matches=False,multiple_bodies=False)
    if point.get('kind')!='located':return r
    r['chapter_matches']=point['chapter_uid']==source_uid
    r['summary_present']=point['summary_present'] and bool(point['summary'])
    if not r['chapter_matches']:return r
    model=FilteredSource(source,allow_multiple_bodies=True);r['multiple_bodies']=model.body_count>1
    indices=[i for i,n in enumerate(model.starts) if n==point['chapter_offset'] and not model.characters[i].isspace()]
    r['visible_boundary']=len(indices)==1
    if not r['visible_boundary']:return r
    try:model.anchor_at(point['chapter_offset']);r['unique_anchor']=True
    except CoordinateError:pass
    if r['summary_present']:
        expected=''.join(c for c in point['summary'] if not c.isspace())
        actual=''.join(c for c in model.characters[indices[0]:] if not c.isspace())[:len(expected)]
        r['summary_matches']=bool(expected) and actual==expected
    return r
