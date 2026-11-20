-- Real book in an isolated tmpfs profile; only fixed boolean evidence escapes.
return function(host,reader,pump,report,mode,home)
    local UI=require('ui/uimanager')
    local json=require('json')
    local config=assert(reader.document.configurable)
    local anchor=reader.document:getXPointer()
    local file=home..'/reader-margins-expected.json'
    if mode=='reopen' then
        local input=assert(io.open(file,'rb'));local saved=json.decode(input:read('*a'));input:close()
        assert(config.h_page_margins[1]==saved.l and config.h_page_margins[2]==saved.r
            and config.t_page_margin==saved.t and config.b_page_margin==saved.b
            and config.sync_t_b_page_margins==saved.sync)
    end
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    assert(host:onShowWeReadQuickMenu());UI:forceRePaint()
    assert(assert(UI:getTopmostVisibleWidget()):getButtonById('reader_typography')):onTapSelectButton()
    pump(function() return host._weread_reader_typography~=nil end)
    local parent=assert(host._weread_reader_typography)
    assert(parent.dialog:getButtonById('typography_margins')):onTapSelectButton()
    pump(function() return host._weread_reader_margins~=nil end)
    local state=assert(host._weread_reader_margins)
    local function button(id) return assert(state.dialog:getButtonById(id)) end
    UI:forceRePaint();assert(state.dialog:getContentSize().h<=require('device').screen:getHeight())
    report.reader_margins_stage=1
    if mode=='live' then
        local l,r,t,b=config.h_page_margins[1],config.h_page_margins[2],config.t_page_margin,config.b_page_margin
        local dh=(l<=135 and r<=135) and 5 or -5
        local dv=(t<=135 and b<=135) and 5 or -5
        button(dh>0 and 'margin_horizontal_up' or 'margin_horizontal_down'):onTapSelectButton()
        button(dv>0 and 'margin_vertical_up' or 'margin_vertical_down'):onTapSelectButton()
        pump(function() return not state.apply_task end)
        local function clamp(value) return math.max(0,math.min(140,value)) end
        assert(config.h_page_margins[1]==clamp(l+dh) and config.h_page_margins[2]==clamp(r+dh)
            and config.t_page_margin==clamp(t+dv) and config.b_page_margin==clamp(b+dv))
    end
    report.reader_margins_stage=2
    if mode=='live' then
        button('margin_default'):onTapSelectButton()
        local confirm=assert(state.confirm);confirm.ok_callback();UI:close(confirm)
    end
    local defaults=assert(G_reader_settings:readSetting('copt_h_page_margins'))
    assert(defaults[1]==config.h_page_margins[1] and defaults[2]==config.h_page_margins[2]
        and G_reader_settings:readSetting('copt_t_page_margin')==config.t_page_margin
        and G_reader_settings:readSetting('copt_b_page_margin')==config.b_page_margin
        and G_reader_settings:readSetting('copt_sync_t_b_page_margins')==config.sync_t_b_page_margins)
    report.reader_margins_stage=3
    button('margin_back'):onTapSelectButton();pump(function() return not parent.hidden end)
    assert(not host._weread_reader_margins)
    assert(parent.dialog:getButtonById('typography_close')):onTapSelectButton()
    assert(not host._weread_reader_typography);UI:forceRePaint()
    assert(reader.document:isXPointerInCurrentPage(anchor))
    if mode=='live' then
        local output=assert(io.open(file,'wb'))
        assert(output:write(json.encode{l=config.h_page_margins[1],r=config.h_page_margins[2],
            t=config.t_page_margin,b=config.b_page_margin,sync=config.sync_t_b_page_margins}));output:close()
    end
    report.reader_margins_stage=4
    return true
end
