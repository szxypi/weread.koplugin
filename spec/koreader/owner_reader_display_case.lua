-- A real book in an isolated tmpfs profile; only fixed status fields leave it.
return function(host,reader,pump,report,mode,home)
    local UI=require('ui/uimanager')
    local json=require('json')
    local footer=assert(reader.view.footer)
    local anchor=reader.document:getXPointer()
    local file=home..'/reader-display-expected.json'
    if mode=='reopen' then
        local input=assert(io.open(file,'rb'));local saved=json.decode(input:read('*a'));input:close()
        for key,value in pairs(saved) do assert(footer.settings[key]==value,'footer setting not restored') end
    end
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    assert(host:onShowWeReadQuickMenu());UI:forceRePaint()
    assert(assert(UI:getTopmostVisibleWidget()):getButtonById('reader_display')):onTapSelectButton()
    pump(function() return host._weread_reader_display~=nil end)
    local state=assert(host._weread_reader_display)
    UI:forceRePaint();assert(state.dialog:getContentSize().h<=require('device').screen:getHeight())
    report.reader_display_stage=1
    local function press(id)
        local button=assert(state.dialog:getButtonById('display_'..id))
        assert(button.enabled~=false)
        button:onTapSelectButton();pump(function() return not state.refresh_task end)
        assert(host._weread_reader_display==state)
    end
    if mode=='live' then
        for _,id in ipairs({'all_at_once','percentage','time','progress_bar','page_progress'}) do
            local key=id=='progress_bar' and 'disable_progress_bar' or id
            local before=footer.settings[key]==true
            press(id);assert((footer.settings[key]==true)~=before)
        end
    end
    report.reader_display_stage=2
    if mode=='live' then
        local before=reader.view.footer_visible
        press('visible');assert(reader.view.footer_visible~=before)
        press('visible');assert(reader.view.footer_visible==before)
    end
    report.reader_display_stage=3
    assert(state.dialog:getButtonById('display_close')):onTapSelectButton()
    assert(not host._weread_reader_display);UI:forceRePaint()
    assert(reader.document:isXPointerInCurrentPage(anchor),'footer reflow lost reading position')
    if mode=='live' then
        local saved={all_at_once=footer.settings.all_at_once,percentage=footer.settings.percentage,
            time=footer.settings.time,disable_progress_bar=footer.settings.disable_progress_bar,
            page_progress=footer.settings.page_progress}
        local output=assert(io.open(file,'wb'));assert(output:write(json.encode(saved)));output:close()
    end
    report.reader_display_stage=4
    return true
end
