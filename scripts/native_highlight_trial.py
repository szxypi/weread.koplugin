"""Strict native bounded highlight payload/receipt schemas, sharing the private reader."""
from copy import deepcopy
import json
from annotation_experiment_model import valid_key
from highlight_trial_model import request
from run_native_selection_trial import validate_payload as validate_selection
from verify_owner_reading import validate_stage as validate_reading

FLAGS={'permit_writes','source_reference','native_controls','exact_creation_body','cache_verified','local_pending_kept','dispatch_blocked','heartbeat'}
COUNTS={'steps':2,'native_gets':40,'native_posts':2,'blocked_posts':1,'native_denied':32,'failed_line':10000}


def validate_stage(stage,armed,complete=True,*,styles=False,color_style=False):
    if not isinstance(stage,dict):raise ValueError('native_highlight/stage')
    addon=stage.get('selection_trial')
    if type(styles) is not bool or type(color_style) is not bool or styles and color_style:raise ValueError('native_highlight/modes')
    flags=FLAGS|({'style_controls','color_controls'} if color_style else {'style_controls'} if styles else set())
    counts=dict(COUNTS,steps=4,native_posts=4,style_displays=2 if color_style else 3) if styles or color_style else COUNTS
    if (not isinstance(addon,dict) or set(addon)!=flags|set(counts)|{'phase'}
            or any(type(addon[k]) is not bool for k in flags) or addon['permit_writes'] is not armed
            or any(type(addon[k]) is not int or not 0<=addon[k]<=cap for k,cap in counts.items())
            or addon['phase'] not in (('init','create','color3','style2','delete','complete') if color_style else ('init','create','style0','style2','delete','complete') if styles else ('init','create','delete','complete'))):raise ValueError('native_highlight/stage')
    validate_reading({k:v for k,v in stage.items() if k!='selection_trial'},'live',selection_preview=True)
    if complete and (stage['result']!='PASS' or addon['phase']!='complete' or addon['native_denied'] or addon['failed_line']
            or not all(addon[k] for k in ('source_reference','native_controls','exact_creation_body','heartbeat'))
            or addon['steps']!=((4 if styles or color_style else 2) if armed else 0) or addon['native_posts']!=((4 if styles or color_style else 2) if armed else 0)
            or addon['blocked_posts']!=(0 if armed else 1) or addon['cache_verified'] is not armed
            or addon['native_gets']<(12 if armed else 6) or addon['local_pending_kept'] is armed or addon['dispatch_blocked'] is armed):
        raise ValueError('native_highlight/incomplete')
    if complete and (styles or color_style) and (addon['style_controls'] is not armed or addon['style_displays']!=((2 if color_style else 3) if armed else 0) or color_style and addon['color_controls'] is not armed):raise ValueError('native_highlight/style_incomplete')
    return stage


def validate_payload(payload,armed,mock_port,*,styles=False,color_style=False):
    if not isinstance(payload,dict) or 'highlight_trial' not in payload or len(json.dumps(payload,ensure_ascii=False).encode())>256*1024:raise ValueError('native_highlight/input')
    common={k:v for k,v in payload.items() if k!='highlight_trial'};validate_selection(common,armed,mock_port)
    if type(styles) is not bool or type(color_style) is not bool or styles and color_style:raise ValueError('native_highlight/modes')
    trial=payload['highlight_trial'];cfg=payload['selection_preview'];body=cfg['body']
    if (not isinstance(trial,dict) or set(trial)!=({'create_body','original_ids','color_style'} if color_style else {'create_body','original_ids','styles'} if styles else {'create_body','original_ids'})
            or styles and trial['styles'] is not True or color_style and (trial['color_style'] is not True or not trial['original_ids'] or not payload['selection_trial']['original_ids'])
            or trial['create_body']!=request(dict(bookId=body['bookId'],chapterUid=body['chapterUid'],bookVersion=body['bookVersion'],range=body['range'],abstract=body['abstract']))
            or not isinstance(trial['original_ids'],list) or len(trial['original_ids'])>5000
            or any(not valid_key(k) for k in trial['original_ids']) or len(set(trial['original_ids']))!=len(trial['original_ids'])):
        raise ValueError('native_highlight/input')
    return deepcopy(payload)
