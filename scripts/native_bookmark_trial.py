"""Strict point-bookmark payload and complete native acceptance receipts."""
from copy import deepcopy
import json
from annotation_experiment_model import valid_key
from bookmark_reference import validate as reference
from bookmark_point import point_range
from native_highlight_trial import validate_stage as base_stage
from run_native_selection_trial import validate_payload as selection_payload
from my_cloud_marks_model import integer,text

FLAGS={'viewport_bound','bookmark_navigation','view_mode_restored'}


def validate_stage(stage,armed,complete=True):
    addon=stage.get('selection_trial') if isinstance(stage,dict) else None
    if not isinstance(addon,dict) or any(type(addon.get(key)) is not bool for key in FLAGS):raise ValueError('native_bookmark/stage')
    diagnostic=addon.get('shelf_check')
    if 'shelf_check' in addon:
        fields={'fetches','fetch_error','cache_calls','metadata_valid','cached','source','worker_result'}
        if (complete or stage.get('result')!='UNVERIFIED' or stage.get('phase')!='shelf' or not isinstance(diagnostic,dict) or set(diagnostic)!=fields
                or any(not integer(diagnostic[k],10) for k in fields-{'metadata_valid','cached'})
                or any(type(diagnostic[k]) is not bool for k in ('metadata_valid','cached'))):raise ValueError('native_bookmark/shelf_diagnostic')
    base=deepcopy(stage);base['selection_trial']={k:v for k,v in addon.items() if k not in FLAGS|{'shelf_check'}}
    base_stage(base,armed,complete)
    if complete and (not addon['viewport_bound'] or not addon['view_mode_restored'] or addon['bookmark_navigation'] is not armed):
        raise ValueError('native_bookmark/incomplete')
    return stage


def validate_payload(payload,armed,mock_port):
    if not isinstance(payload,dict) or 'bookmark_trial' not in payload or len(json.dumps(payload,ensure_ascii=False).encode())>256*1024:
        raise ValueError('native_bookmark/input')
    selection_payload({k:v for k,v in payload.items() if k!='bookmark_trial'},armed,mock_port)
    trial=payload['bookmark_trial']
    if not isinstance(trial,dict) or set(trial)!={'create_body','reference','first','original_ids'}:raise ValueError('native_bookmark/input')
    row=reference(trial['reference'],payload['book_id']);body=trial['create_body']
    if (row['source']['chapter_uid']!=payload['chapter_uid'] or row['source']['raw_sha256']!=payload['source_raw_sha256']
            or not integer(trial['first'],16*1024*1024) or not isinstance(body,dict)
            or set(body)!={'bookId','chapterUid','bookVersion','type','style','range','markText'}
            or body['bookId']!=payload['book_id'] or type(body['chapterUid']) is not int or body['chapterUid']!=row['chapterUid']
            or body['bookVersion']!=payload['selection_preview']['body']['bookVersion'] or not integer(body['bookVersion'],2147483647) or body['bookVersion']==0
            or type(body['type']) is not int or body['type']!=0 or type(body['style']) is not int or body['style']!=0
            or body['range']!=row['range'] or body['markText']!=row['markText'] or not text(body['markText'],4096,False)
            or not isinstance(trial['original_ids'],list) or len(trial['original_ids'])>5000
            or len(set(trial['original_ids']))!=len(trial['original_ids']) or any(not valid_key(key) for key in trial['original_ids'])):
        raise ValueError('native_bookmark/input')
    point_range(body['range']);return deepcopy(payload)
