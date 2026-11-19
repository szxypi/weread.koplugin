"""One source-bound UTF-16 bookmark on a self-authored TXT fixture."""
from annotation_experiment_model import digest
from cb_fixture_bookmark_trial import Intent,validate_plan
from cb_txt_highlight_trial import BODY as BASE,TEXT,prepare as prepare_highlight

# The long tail lets both simulated screen sizes align the chosen point at
# the viewport start; content is entirely synthetic and contains one emoji.
BODY=BASE+('Additional synthetic paragraph for bookmark viewport alignment.\n'*160).encode()


def prepare(owner,book,attempt,sample,version,baseline):
    plan,highlight=prepare_highlight(owner,book,attempt,sample,version,baseline,range_unit='utf16')
    raw=sample['source'].removeprefix('\ufeff');at=raw.index(TEXT)
    point=len(raw[:at].encode('utf-16-le'))//2;preview=raw[at:at+140].strip()
    if (highlight['range'].split('-')[0]!=str(point) or len(''.join(preview.split()))<12
            or raw.count(preview)!=1):raise ValueError('cb_txt_bookmark/source')
    body=dict(bookId=book,chapterUid=highlight['chapterUid'],bookVersion=version,type=0,style=0,
              range=str(point),markText=preview)
    return validate_plan(dict(plan,protocol='cb-synthetic-bookmark-create-remove-v1',request_sha256=digest(body))),body
