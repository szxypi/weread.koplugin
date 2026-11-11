"""Independent own-thought text projection; display ranges never drive writes."""
from my_cloud_marks_model import identifier,integer,text


class ThoughtsError(ValueError):pass


def fail(reason):raise ThoughtsError('my_thoughts_'+reason)


def scope(value,identity,owner=None):
    if not isinstance(value,dict):fail('object')
    for key in ('bookId','book_id'):
        if value.get(key) is not None and str(value[key])!=identity:fail('book')
    for key in ('userVid','vid'):
        if owner is not None and value.get(key) is not None and str(value[key])!=owner:fail('owner')


def entry(value):
    if not isinstance(value,dict):fail('entry')
    key=value.get('reviewId')
    if not text(key,256,False) or any(c.isspace() for c in key):fail('identity')
    out=dict(reviewId=key)
    for name,limit in [('content',131072),('abstract',65536),('chapterName',4096),('range',256)]:
        if value.get(name) is not None:
            if not text(value[name],limit):fail('text')
            out[name]=value[name]
    if 'content' not in out:fail('text')
    for name in ('chapterUid','chapterIdx','type','createTime','isPrivate','isFinish'):
        if value.get(name) is not None:
            maximum=4102444800 if name=='createTime' else 1 if name in ('isPrivate','isFinish') else 2147483647
            if not integer(value[name],maximum):fail('number')
            out[name]=value[name]
    return out


def page(source,identity,owner):
    if not identifier(identity) or not identifier(owner):fail('scope')
    scope(source,identity,owner)
    for key in ('errcode','errCode'):
        if source.get(key) is not None and (type(source[key]) is not int or source[key]!=0):fail('rejected')
    if source.get('succ') not in (None,True,1):fail('rejected')
    rows=source.get('reviews');total=source.get('totalCount');more=source.get('hasMore')
    if not isinstance(rows,list) or len(rows)>5000 or not integer(total,5000) or type(more) not in (int,bool) or more not in (0,1):fail('page')
    out=[];seen=set()
    for row in rows:
        scope(row,identity,owner);review=row.get('review')
        scope(review,identity,owner)
        # Require explicit book/owner proof for each row; mine=1 alone is not proof.
        if str(review.get('bookId'))!=identity:fail('book')
        author=review.get('author')
        if author is not None:scope(author,identity,owner)
        if review.get('book') is not None:scope(review['book'],identity,owner)
        explicit=[str(v) for v in (review.get('userVid'),review.get('vid'),author.get('userVid') if isinstance(author,dict) else None) if v is not None]
        if not explicit or any(value!=owner for value in explicit):fail('owner')
        item=entry(review)
        if row.get('reviewId') is not None and row['reviewId']!=item['reviewId']:fail('identity')
        if item['reviewId'] in seen:fail('duplicate')
        seen.add(item['reviewId']);out.append(item)
    if len(out)>total:fail('page')
    # Actual native replies reported hasMore=0 for a truncated count=1/2 prefix.
    # Completion requires both the declared total and the terminal flag.
    return dict(reviews=out,total_count=total,has_more=bool(more) or len(out)<total)


def complete(source,identity,owner,now):
    if not integer(now,2**53-1) or now==0:fail('time')
    result=page(source,identity,owner)
    if result['has_more']:fail('incomplete')
    return dict(schema=1,book_id=identity,fetched_at=now,reviews=result['reviews'])
