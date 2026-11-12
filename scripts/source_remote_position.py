"""Source-position availability; never invent chapter indices from list order."""
import re
from verify_reader_progress import project,find_node,ProgressError,identity


def positive(value):
    text=identity(value)
    return text if text and re.fullmatch('[1-9][0-9]{0,19}',text) else None


def catalog_index(chapters,uid):
    if not isinstance(chapters,list) or not 1<=len(chapters)<=10000:raise ProgressError('progress_source_incomplete')
    selected=None;seen=set();indices=set()
    for row in chapters:
        if not isinstance(row,dict):raise ProgressError('progress_source_incomplete')
        ids=[positive(row[k]) for k in ('chapterUid','chapterId','chapter_uid') if k in row]
        values=[row[k] for k in ('chapterIdx','chapterIndex','chapter_idx') if k in row]
        if (not ids or None in ids or len(set(ids))!=1 or ids[0] in seen
                or any(type(n) not in (int,float) or not 0<=n<=1000000 or int(n)!=n for n in values)
                or values and (len(set(values))!=1 or values[0] in indices)):raise ProgressError('progress_source_incomplete')
        seen.add(ids[0])
        if values:indices.add(values[0])
        if ids[0]==uid and values:selected=int(values[0])
    if selected is None:raise ProgressError('progress_source_incomplete')
    return selected


def resolve(raw,book_id,chapters,source='web'):
    """Return original raw-percent units with an explicitly sourced index."""
    p=project(raw,book_id,source);node=find_node(raw,book_id)
    present_index=any(k in node for k in ('chapterIdx','chapterIndex','chapter_idx'))
    if (identity(p.get('chapter_uid'))=='0' and p['raw_percent']==0 and p['has_chapter_offset'] and p['chapter_offset']==0
            and p['summary']=='' and (not present_index or p['chapter_idx']==0)):
        raise ProgressError('progress_no_chapter')
    uid=positive(p.get('chapter_uid'))
    if not uid or not p['has_chapter_offset']:raise ProgressError('progress_source_incomplete')
    index=catalog_index(chapters,uid)
    if present_index and p['chapter_idx']!=index:raise ProgressError('progress_source_incomplete')
    p.update(chapter_idx=index,has_chapter_index=True,chapter_index_source='response' if present_index else 'catalog')
    return p


def outcome(raw,book_id,chapters,source='web'):
    try:return dict(ok=True,position=resolve(raw,book_id,chapters,source))
    except ProgressError as error:return dict(ok=False,reason=str(error))


def public_report(report,secrets):
    """Reject a diagnostic containing a private literal, including JSON escapes."""
    import json
    serialized=json.dumps(report,ensure_ascii=True)
    if any(len(s)>=8 and any(v in serialized or json.dumps(v,ensure_ascii=True)[1:-1] in serialized
                            for v in (s,json.dumps(s,ensure_ascii=True)[1:-1])) for s in secrets):
        return dict(result='UNVERIFIED',reason='report_privacy',account_data_posts=0,authentication_posts=0)
    return report
