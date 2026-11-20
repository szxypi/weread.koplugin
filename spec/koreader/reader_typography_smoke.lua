-- Synthetic book, actual ReaderUI, CRE reflow and plugin event lifecycle.
return function(reader,host,pump,shot,clean,reopen,evidence)
    local UI=require('ui/uimanager')
    local json=require('json')
    local file=evidence..'/typography-expected.json'
    local font=assert(reader.font);local config=assert(font.configurable)
    if reopen then
        local input=assert(io.open(file,'rb'));local expected=json.decode(input:read('*a'));input:close()
        assert(config.font_size==expected.size and config.line_spacing==expected.spacing
            and config.font_base_weight==expected.weight and font.font_face==expected.face,
            'fresh offline reader did not restore typography')
        assert(G_reader_settings:readSetting('copt_font_size')==expected.size
            and G_reader_settings:readSetting('copt_line_spacing')==expected.spacing
            and G_reader_settings:readSetting('copt_font_base_weight')==expected.weight
            and G_reader_settings:readSetting('cre_font')==expected.face,'global defaults were not persisted')
        return
    end
    local anchor=reader.document:getXPointer()
    local function open()
        clean(reader);assert(host:onShowWeReadQuickMenu());UI:forceRePaint()
        local quick=assert(UI:getTopmostVisibleWidget())
        assert(quick:getButtonById('reader_typography')):onTapSelectButton()
        pump(function() return host._weread_reader_typography~=nil end)
        local state=assert(host._weread_reader_typography);UI:forceRePaint()
        assert(state.dialog:getContentSize().h<=require('device').screen:getHeight(),'reading settings exceed screen')
        return state
    end
    local state=open();shot('reader-typography')
    local counts={}
    local originals={}
    for _,name in ipairs({'onSetFontSize','onSetLineSpace','onSetFontBaseWeight'}) do
        local method=assert(font[name]);originals[name]=method;counts[name]=0
        font[name]=function(self,value) counts[name]=counts[name]+1;return method(self,value) end
    end
    local before_size,before_spacing,before_weight=config.font_size,config.line_spacing,config.font_base_weight
    local function button(id) return assert(state.dialog:getButtonById(id)) end
    assert(before_size<=253 and before_spacing<=195 and before_weight<=2.75)
    button('typography_size_up'):onTapSelectButton()
    button('typography_size_up'):onTapSelectButton()
    assert(counts.onSetFontSize==0,'typing changes were not coalesced')
    pump(function() return counts.onSetFontSize==1 and state.apply_task==nil end)
    assert(config.font_size==before_size+2)
    button('typography_spacing_up'):onTapSelectButton()
    button('typography_weight_up'):onTapSelectButton()
    pump(function() return counts.onSetLineSpace==1 and counts.onSetFontBaseWeight==1 end)
    assert(config.line_spacing==before_spacing+5 and config.font_base_weight==before_weight+.25)
    UI:forceRePaint();shot('reader-typography-adjusted')
    button('typography_font'):onTapSelectButton()
    local menu=assert(state.menu);local chosen
    for _,item in ipairs(menu.item_table) do if item.mandatory~='✓' then chosen=item;break end end
    assert(chosen,'fixture needs at least two fonts')
    local prior=font.font_face;menu:onMenuSelect(chosen)
    assert(font.font_face~=prior and not state.menu,'native font choice was not applied')
    local old_default=G_reader_settings:readSetting('copt_font_size')
    button('typography_default'):onTapSelectButton()
    local confirm=assert(state.confirm);UI:forceRePaint();shot('reader-typography-default')
    UI:close(confirm);assert(G_reader_settings:readSetting('copt_font_size')==old_default,'dismissed confirmation changed defaults')
    button('typography_default'):onTapSelectButton();confirm=assert(state.confirm)
    confirm.ok_callback();UI:close(confirm)
    assert(G_reader_settings:readSetting('copt_font_size')==config.font_size
        and G_reader_settings:readSetting('copt_line_spacing')==config.line_spacing
        and G_reader_settings:readSetting('copt_font_base_weight')==config.font_base_weight
        and G_reader_settings:readSetting('cre_font')==font.font_face,'confirmed defaults were not saved')
    for name,method in pairs(originals) do font[name]=method end
    button('typography_close'):onTapSelectButton();assert(not host._weread_reader_typography)
    UI:forceRePaint()
    assert(reader.document:isXPointerInCurrentPage(anchor),'typography reflow lost the original reading position')
    state=open();button= function(id) return assert(state.dialog:getButtonById(id)) end
    button('typography_size_down'):onTapSelectButton();assert(state.apply_task)
    host:onSuspend();assert(not host._weread_reader_typography,'suspend retained pending settings')
    host:onResume();UI:forceRePaint()
    assert(config.font_size==before_size+2,'suspend applied a canceled setting')
    local output=assert(io.open(file,'wb'))
    assert(output:write(json.encode{size=config.font_size,spacing=config.line_spacing,
        weight=config.font_base_weight,face=font.font_face}));output:close()
    clean(reader)
end
