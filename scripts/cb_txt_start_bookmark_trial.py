"""A beginning-of-file TXT bookmark on a short self-authored fixture."""
from annotation_experiment_model import digest
from cb_fixture_bookmark_trial import Intent,validate_plan
from cb_txt_highlight_trial import BODY,TEXT,prepare as prepare_highlight


def prepare(owner,book,attempt,sample,version,baseline):
    plan,highlight=prepare_highlight(owner,book,attempt,sample,version,baseline,range_unit='utf16')
    raw=sample['source'].removeprefix('\ufeff');preview=raw[:140].strip()
    if (not raw.startswith('A self-authored test begins') or len(''.join(preview.split()))<12
            or raw.count(preview)!=1):raise ValueError('cb_txt_start_bookmark/source')
    body=dict(bookId=book,chapterUid=highlight['chapterUid'],bookVersion=version,type=0,style=0,
              range='0',markText=preview)
    return validate_plan(dict(plan,protocol='cb-synthetic-bookmark-create-remove-v1',request_sha256=digest(body))),body
