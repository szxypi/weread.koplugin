-- Real book in an isolated tmpfs profile; only fixed boolean evidence escapes.
return function(host,reader,pump,report,mode,home)
    local UI=require('ui/uimanager')
    local json=require('json')
    local font=assert(reader.font);local config=assert(font.configurable)
    local original=reader.document:getXPointer()
    local file=home..'/reader-typography-expected.json'
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    assert(host:onShowWeReadQuickMenu());UI:forceRePaint()
    local quick=assert(UI:getTopmostVisibleWidget())
    assert(quick:getButtonById('reader_typography')):onTapSelectButton()
    pump(function() return host._weread_reader_typography~=nil end)
    local state=assert(host._weread_reader_typography)
    local function button(id) return assert(state.dialog:getButtonById(id)) end
    UI:forceRePaint();assert(state.dialog:getContentSize().h<=require('device').screen:getHeight())
    report.reader_typography_stage=1
    if mode=='live' then
        local size,spacing,weight=config.font_size,config.line_spacing,config.font_base_weight
        local ds=size<255 and 1 or -1
        local dl=spacing<=195 and 5 or -5
        local dw=weight<=2.75 and .25 or -.25
        button(ds>0 and 'typography_size_up' or 'typography_size_down'):onTapSelectButton()
        button(dl>0 and 'typography_spacing_up' or 'typography_spacing_down'):onTapSelectButton()
        button(dw>0 and 'typography_weight_up' or 'typography_weight_down'):onTapSelectButton()
        pump(function() return not state.apply_task end)
        assert(config.font_size==size+ds and config.line_spacing==spacing+dl and config.font_base_weight==weight+dw)
    else
        local input=assert(io.open(file,'rb'));local saved=json.decode(input:read('*a'));input:close()
        assert(config.font_size==saved.size and config.line_spacing==saved.spacing
            and config.font_base_weight==saved.weight and font.font_face==saved.face)
    end
    report.reader_typography_stage=2
    button('typography_font'):onTapSelectButton()
    local menu=assert(state.menu);local selected,alternative
    for _,item in ipairs(menu.item_table) do
        if item.mandatory=='✓' then selected=item else alternative=alternative or item end
    end
    assert(selected and alternative)
    if mode=='live' then
        local old=font.font_face;menu:onMenuSelect(alternative);assert(font.font_face~=old and not state.menu)
        button('typography_default'):onTapSelectButton()
        local confirm=assert(state.confirm);confirm.ok_callback();UI:close(confirm)
    else
        UI:close(menu);assert(not state.menu)
    end
    assert(G_reader_settings:readSetting('copt_font_size')==config.font_size
        and G_reader_settings:readSetting('copt_line_spacing')==config.line_spacing
        and G_reader_settings:readSetting('copt_font_base_weight')==config.font_base_weight
        and G_reader_settings:readSetting('cre_font')==font.font_face)
    report.reader_typography_stage=3
    button('typography_close'):onTapSelectButton();assert(not host._weread_reader_typography)
    UI:forceRePaint();assert(reader.document:isXPointerInCurrentPage(original))
    if mode=='live' then
        local output=assert(io.open(file,'wb'))
        assert(output:write(json.encode{size=config.font_size,spacing=config.line_spacing,
            weight=config.font_base_weight,face=font.font_face}));output:close()
    end
    report.reader_typography_stage=4
    return true
end
