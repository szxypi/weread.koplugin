"""Fixed public counters for private, native all-group page acceptance."""
COUNTS=dict(groups=32,memberships=1600,selected_groups=32,forward_pages=1600,reverse_pages=1600,
            selector_views=33,checked_memberships=1600,empty_groups=32)
FLAGS={'reference_matches','cache_matches','native_picker_used','boundaries_verified','closed_callbacks_rejected','pluginloader_host','filemanager_host'}


def validate(value,mode,groups,complete):
    if (not isinstance(value,dict) or set(value)!=set(COUNTS)|FLAGS
            or any(type(value[k]) is not bool for k in FLAGS)):
        raise ValueError('persistent_ui_group_schema')
    if any(type(value[k]) is not int or not 0<=value[k]<=maximum for k,maximum in COUNTS.items()):
        raise ValueError('persistent_ui_group_counts')
    if complete and (not all(value[k] for k in FLAGS) or value['groups']!=groups
            or value['selected_groups']!=groups or value['memberships']!=value['checked_memberships']
            or value['forward_pages']<groups or value['empty_groups']>groups
            or value['selector_views']!=groups+1
            or value['reverse_pages']!=(value['forward_pages']-groups if mode=='reopen' else 0)):
        raise ValueError('persistent_ui_group_incomplete')
    return value['forward_pages']+value['reverse_pages']+value['selector_views']
