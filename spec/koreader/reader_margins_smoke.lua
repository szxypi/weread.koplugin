-- Synthetic book, actual KOReader typesetting, chapter handoff and reopens.
return function(reader,host,pump,shot,clean,reopen,evidence)
    local UI=require('ui/uimanager')
    local json=require('json')
    local config=assert(reader.document.configurable)
    local typeset=assert(reader.typeset)
    local file=evidence..'/margins-expected.json'
    if reopen then
        local input=assert(io.open(file,'rb'));local saved=json.decode(input:read('*a'));input:close()
        assert(config.h_page_margins[1]==saved.l and config.h_page_margins[2]==saved.r
            and config.t_page_margin==saved.t and config.b_page_margin==saved.b
            and config.sync_t_b_page_margins==saved.sync,'reader did not restore margins')
        local horizontal=assert(G_reader_settings:readSetting('copt_h_page_margins'))
        assert(horizontal[1]==saved.l and horizontal[2]==saved.r
            and G_reader_settings:readSetting('copt_t_page_margin')==saved.t
            and G_reader_settings:readSetting('copt_b_page_margin')==saved.b
            and G_reader_settings:readSetting('copt_sync_t_b_page_margins')==saved.sync,
            'global margin defaults were not persisted')
        return
    end
    local anchor=reader.document:getXPointer()
    local function open_parent()
        clean(reader);assert(host:onShowWeReadQuickMenu());UI:forceRePaint()
        local quick=assert(UI:getTopmostVisibleWidget())
        assert(quick:getButtonById('reader_typography')):onTapSelectButton()
        pump(function() return host._weread_reader_typography~=nil end)
        return assert(host._weread_reader_typography)
    end
    local parent=open_parent()
    local function open_margins()
        assert(parent.dialog:getButtonById('typography_margins')):onTapSelectButton()
        pump(function() return host._weread_reader_margins~=nil end)
        local state=assert(host._weread_reader_margins);UI:forceRePaint()
        assert(state.dialog:getContentSize().h<=require('device').screen:getHeight(),'margin panel exceeds screen')
        return state
    end
    local state=open_margins();shot('reader-margins')
    local counts={h=0,v=0}
    local old_h,old_v=assert(typeset.onSetPageHorizMargins),assert(typeset.onSetPageTopAndBottomMargin)
    typeset.onSetPageHorizMargins=function(self,value) counts.h=counts.h+1;return old_h(self,value) end
    typeset.onSetPageTopAndBottomMargin=function(self,value) counts.v=counts.v+1;return old_v(self,value) end
    local before={config.h_page_margins[1],config.h_page_margins[2],config.t_page_margin,config.b_page_margin}
    assert(before[1]<=130 and before[2]<=130 and before[3]<=135 and before[4]<=135)
    local function button(id) return assert(state.dialog:getButtonById(id)) end
    button('margin_horizontal_up'):onTapSelectButton();button('margin_horizontal_up'):onTapSelectButton()
    button('margin_vertical_up'):onTapSelectButton()
    assert(counts.h==0 and counts.v==0,'margin updates were not coalesced')
    pump(function() return counts.h==1 and counts.v==1 and not state.apply_task end)
    assert(config.h_page_margins[1]==before[1]+10 and config.h_page_margins[2]==before[2]+10
        and config.t_page_margin==before[3]+5 and config.b_page_margin==before[4]+5)
    for _,name in ipairs({'margin_compact','margin_standard','margin_wide'}) do
        button(name):onTapSelectButton();pump(function() return not state.apply_task end)
    end
    local h=assert(G_defaults:readSetting('DCREREADER_CONFIG_H_MARGIN_SIZES_XX_LARGE'))
    assert(config.h_page_margins[1]==h[1] and config.h_page_margins[2]==h[2]
        and config.t_page_margin==G_defaults:readSetting('DCREREADER_CONFIG_T_MARGIN_SIZES_XX_LARGE')
        and config.b_page_margin==G_defaults:readSetting('DCREREADER_CONFIG_B_MARGIN_SIZES_XX_LARGE'))
    button('margin_back'):onTapSelectButton();pump(function() return not parent.hidden end)
    assert(not host._weread_reader_margins and host._weread_reader_typography==parent)
    config.sync_t_b_page_margins=1;typeset:onSyncPageTopBottomMargins(true)
    state=open_margins();assert(state.values.sync==1)
    button('margin_compact'):onTapSelectButton();pump(function() return not state.apply_task end)
    local compact_top=G_defaults:readSetting('DCREREADER_CONFIG_T_MARGIN_SIZES_SMALL')
    local compact_bottom=G_defaults:readSetting('DCREREADER_CONFIG_B_MARGIN_SIZES_SMALL')
    local compact=math.floor((compact_top+compact_bottom)/2+.5)
    assert(config.t_page_margin==compact and config.b_page_margin==compact and config.sync_t_b_page_margins==1)
    button('margin_wide'):onTapSelectButton();pump(function() return not state.apply_task end)
    local vertical_before=config.t_page_margin
    button('margin_vertical_up'):onTapSelectButton();pump(function() return not state.apply_task end)
    assert(config.t_page_margin==vertical_before+5 and config.b_page_margin==vertical_before+5
        and config.sync_t_b_page_margins==1 and typeset.sync_t_b_page_margins)
    UI:forceRePaint();shot('reader-margins-adjusted')
    local old_default=G_reader_settings:readSetting('copt_t_page_margin')
    button('margin_default'):onTapSelectButton();local confirm=assert(state.confirm)
    UI:forceRePaint();shot('reader-margins-default')
    UI:close(confirm);assert(G_reader_settings:readSetting('copt_t_page_margin')==old_default)
    button('margin_default'):onTapSelectButton();confirm=assert(state.confirm)
    confirm.ok_callback();UI:close(confirm)
    local saved_h=assert(G_reader_settings:readSetting('copt_h_page_margins'))
    assert(saved_h[1]==config.h_page_margins[1] and saved_h[2]==config.h_page_margins[2]
        and G_reader_settings:readSetting('copt_t_page_margin')==config.t_page_margin
        and G_reader_settings:readSetting('copt_b_page_margin')==config.b_page_margin
        and G_reader_settings:readSetting('copt_sync_t_b_page_margins')==1)
    typeset.onSetPageHorizMargins,typeset.onSetPageTopAndBottomMargin=old_h,old_v
    button('margin_back'):onTapSelectButton();pump(function() return not parent.hidden end)
    parent.dialog:getButtonById('typography_close'):onTapSelectButton()
    assert(not host._weread_reader_margins and not host._weread_reader_typography)
    UI:forceRePaint();assert(reader.document:isXPointerInCurrentPage(anchor),'margin reflow lost original reading position')
    parent=open_parent();state=open_margins();local saved_top=config.t_page_margin
    button('margin_vertical_down'):onTapSelectButton();assert(state.apply_task)
    host:onSuspend();assert(not host._weread_reader_margins and not host._weread_reader_typography)
    host:onResume();UI:forceRePaint();assert(config.t_page_margin==saved_top,'suspend applied canceled margins')
    local output=assert(io.open(file,'wb'))
    assert(output:write(json.encode{l=config.h_page_margins[1],r=config.h_page_margins[2],
        t=config.t_page_margin,b=config.b_page_margin,sync=config.sync_t_b_page_margins}));output:close()
    clean(reader)
end
