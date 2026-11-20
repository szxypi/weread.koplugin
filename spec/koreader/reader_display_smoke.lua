-- Exercise the actual KOReader footer callbacks with a synthetic book.
return function(reader,host,pump,shot,clean,reopen,evidence)
    local UI=require('ui/uimanager')
    local json=require('json')
    local footer=assert(reader.view.footer)
    local file=evidence..'/display-expected.json'
    if reopen then
        local input=assert(io.open(file,'rb'));local saved=json.decode(input:read('*a'));input:close()
        for key,value in pairs(saved) do
            assert(footer.settings[key]==value,'reader did not restore footer setting '..key)
        end
        return
    end
    local anchor=reader.document:getXPointer()
    clean(reader);assert(host:onShowWeReadQuickMenu());UI:forceRePaint()
    local quick=assert(UI:getTopmostVisibleWidget())
    assert(quick:getButtonById('reader_display')):onTapSelectButton()
    pump(function() return host._weread_reader_display~=nil end)
    local state=assert(host._weread_reader_display)
    UI:forceRePaint()
    assert(state.dialog:getContentSize().h<=require('device').screen:getHeight(),'display panel exceeds screen')
    shot('reader-display')
    local function press(id)
        local button=assert(state.dialog:getButtonById('display_'..id),id)
        assert(button.enabled~=false,id..' unavailable')
        button:onTapSelectButton()
        pump(function() return not state.refresh_task end)
        assert(host._weread_reader_display==state,id..' closed panel')
    end
    for _,id in ipairs({'all_at_once','percentage','time','progress_bar','page_progress'}) do
        local key=id=='progress_bar' and 'disable_progress_bar' or id
        local previous=footer.settings[key]==true
        press(id)
        assert((footer.settings[key]==true)~=previous,id..' did not change footer')
    end
    local visible=reader.view.footer_visible
    press('visible');assert(reader.view.footer_visible~=visible,'footer visibility did not change')
    press('visible');assert(reader.view.footer_visible==visible,'footer visibility did not restore')
    UI:forceRePaint();shot('reader-display-adjusted')
    assert(reader.document:isXPointerInCurrentPage(anchor),'status bar reflow lost reading position')
    local saved={all_at_once=footer.settings.all_at_once,percentage=footer.settings.percentage,
        time=footer.settings.time,disable_progress_bar=footer.settings.disable_progress_bar,
        page_progress=footer.settings.page_progress}
    local output=assert(io.open(file,'wb'));assert(output:write(json.encode(saved)));output:close()
    assert(state.dialog:getButtonById('display_close')):onTapSelectButton()
    assert(not host._weread_reader_display)
    clean(reader)
end
