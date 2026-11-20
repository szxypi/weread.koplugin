-- Per-file margin controls backed by KOReader's live typesetting module.
local ButtonDialog=require('ui/widget/buttondialog')
local ConfirmBox=require('ui/widget/confirmbox')
local UI=require('ui/uimanager')
local util=require('weread.lib.plugin_util')
local _=util.tr
local M={}
local function valid(value)
    return type(value)=='number' and value==value and value%1==0 and value>=0 and value<=140
end
local function copy(value)
    return {l=value.l,r=value.r,t=value.t,b=value.b,sync=value.sync}
end
local function same(a,b)
    return a and b and a.l==b.l and a.r==b.r and a.t==b.t and a.b==b.b and a.sync==b.sync
end
local function read(config,typeset)
    local horizontal=config.h_page_margins
    local native=typeset.unscaled_margins
    local sync=config.sync_t_b_page_margins
    if type(horizontal)~='table' or type(native)~='table' or (sync~=0 and sync~=1)
        or type(typeset.sync_t_b_page_margins)~='boolean' or typeset.sync_t_b_page_margins~=(sync==1) then return nil end
    local value={l=horizontal[1],r=horizontal[2],t=config.t_page_margin,b=config.b_page_margin,sync=sync}
    if not valid(value.l) or not valid(value.r) or not valid(value.t) or not valid(value.b)
        or sync==1 and value.t~=value.b or native[1]~=value.l or native[2]~=value.t
        or native[3]~=value.r or native[4]~=value.b then return nil end
    return value
end

function M.cancel(host)
    local state=host and host._weread_reader_margins
    if state then state.stop(false) end
end

function M.show(host,parent_current,on_closed)
    local ui=host and host.ui;local document=ui and ui.document
    local config=document and document.configurable;local typeset=ui and ui.typeset
    local supported=type(config)=='table' and type(typeset)=='table' and typeset.configurable==config
        and type(typeset.onSetPageHorizMargins)=='function'
        and (type(typeset.onSetPageTopAndBottomMargin)=='function'
            or type(typeset.onSetPageTopMargin)=='function' and type(typeset.onSetPageBottomMargin)=='function')
    local original=supported and read(config,typeset)
    if type(parent_current)~='function' or not original then
        if host and type(host.showInfo)=='function' then host:showInfo(_('Margin settings are unavailable for this file.')) end
        return false
    end
    local allowed,active=pcall(parent_current)
    if not allowed or active~=true then return false end
    M.cancel(host)
    local state={base=copy(original),values=copy(original),pending=false,on_closed=on_closed}
    host._weread_reader_margins=state
    local function current()
        if host._weread_reader_margins~=state or host.ui~=ui or ui.document~=document
            or ui.typeset~=typeset or document.configurable~=config then return false end
        local ok,result=pcall(parent_current)
        return ok and result==true
    end
    local function title()
        local v=state.values
        return util.T(_('Page margins · current file\nLeft %1 / Right %2\nTop %3 / Bottom %4'),v.l,v.r,v.t,v.b)
    end
    local function refresh()
        if current() and state.dialog then pcall(state.dialog.setTitle,state.dialog,title()) end
    end
    local function schedule_refresh()
        if state.refresh_task then UI:unschedule(state.refresh_task) end
        local task
        task=function()
            if state.refresh_task~=task then return end
            state.refresh_task=nil;refresh()
        end
        state.refresh_task=task;UI:scheduleIn(.06,task)
    end
    local function horizontal(value)
        local pair={value.l,value.r};config.h_page_margins=pair
        local ok,result=pcall(typeset.onSetPageHorizMargins,typeset,pair)
        return ok and result~=false
    end
    local function vertical(value)
        config.t_page_margin,config.b_page_margin=value.t,value.b
        if type(typeset.onSetPageTopAndBottomMargin)=='function' then
            local ok,result=pcall(typeset.onSetPageTopAndBottomMargin,typeset,{value.t,value.b})
            return ok and result~=false
        end
        local ok,result=pcall(typeset.onSetPageTopMargin,typeset,value.t)
        if not ok or result==false or not current() then return false end
        ok,result=pcall(typeset.onSetPageBottomMargin,typeset,value.b)
        return ok and result~=false
    end
    local function flush()
        if state.apply_task then UI:unschedule(state.apply_task);state.apply_task=nil end
        if not current() then
            state.pending=false
            if host._weread_reader_margins==state then state.stop(false) end
            return false
        end
        if not state.pending then return true end
        local observed=read(config,typeset)
        if not same(observed,state.base) then
            state.pending=false
            if observed then state.base=copy(observed);state.values=copy(observed) end
            schedule_refresh()
            if type(host.showInfo)=='function' then host:showInfo(_('Page margins changed. Please try again.')) end
            return false
        end
        local old,target=copy(state.base),copy(state.values)
        state.pending=false
        local changed_h=old.l~=target.l or old.r~=target.r
        local changed_v=old.t~=target.t or old.b~=target.b
        local success=true
        if changed_h then success=horizontal(target) end
        if success and current() and changed_v then success=vertical(target) end
        if not current() then return false end
        success=success and same(read(config,typeset),target)
        if not success then
            if changed_h then horizontal(old) end
            if current() and changed_v then vertical(old) end
            if type(host.showInfo)=='function' then host:showInfo(_('Could not apply page margins.')) end
        end
        observed=read(config,typeset)
        if observed then state.base=copy(observed);state.values=copy(observed) end
        schedule_refresh()
        return success==true
    end
    state.stop=function(apply)
        if host._weread_reader_margins~=state then return end
        if apply and state.pending then flush() end
        host._weread_reader_margins=nil
        if state.apply_task then UI:unschedule(state.apply_task);state.apply_task=nil end
        if state.refresh_task then UI:unschedule(state.refresh_task);state.refresh_task=nil end
        if state.confirm then local confirm=state.confirm;state.confirm=nil;UI:close(confirm) end
        if state.dialog then local dialog=state.dialog;state.dialog=nil;UI:close(dialog) end
        local closed=state.on_closed;state.on_closed=nil
        if type(closed)=='function' then pcall(closed) end
    end
    local function enqueue(value)
        if not current() then return end
        state.values=value;state.pending=not same(value,state.base)
        schedule_refresh()
        if state.apply_task then UI:unschedule(state.apply_task);state.apply_task=nil end
        if not state.pending then return end
        local task
        task=function()
            if state.apply_task~=task then return end
            state.apply_task=nil;flush()
        end
        state.apply_task=task;UI:scheduleIn(.4,task)
    end
    local function adjust(horizontal_axis,delta)
        local value=copy(state.values)
        local first,second=horizontal_axis and 'l' or 't',horizontal_axis and 'r' or 'b'
        value[first]=math.max(0,math.min(140,value[first]+delta))
        value[second]=math.max(0,math.min(140,value[second]+delta))
        enqueue(value)
    end
    local function defaults_value(name,fallback)
        if G_defaults and type(G_defaults.readSetting)=='function' then
            local ok,value=pcall(G_defaults.readSetting,G_defaults,name)
            if ok and value~=nil then return value end
        end
        return fallback
    end
    local function preset(kind)
        local specs={compact={'SMALL',5,5},standard={'MEDIUM',10,15},wide={'XX_LARGE',30,30}}
        local spec=specs[kind];if not spec then return end
        local h=defaults_value('DCREREADER_CONFIG_H_MARGIN_SIZES_'..spec[1],{spec[2],spec[2]})
        local vertical_name=kind=='standard' and 'LARGE' or spec[1]
        local top=defaults_value('DCREREADER_CONFIG_T_MARGIN_SIZES_'..vertical_name,spec[3])
        local bottom=defaults_value('DCREREADER_CONFIG_B_MARGIN_SIZES_'..vertical_name,spec[3])
        if type(h)~='table' or not valid(h[1]) or not valid(h[2]) or not valid(top) or not valid(bottom) then
            if type(host.showInfo)=='function' then host:showInfo(_('This margin preset is unavailable.')) end
            return
        end
        if state.values.sync==1 and top~=bottom then top=math.floor((top+bottom)/2+.5);bottom=top end
        enqueue{l=h[1],r=h[2],t=top,b=bottom,sync=state.values.sync}
    end
    local function save_default()
        if not current() or state.pending and not flush() or not current() then return end
        local defaults=G_reader_settings
        if type(defaults)~='table' or type(defaults.saveSetting)~='function' or type(defaults.readSetting)~='function'
            or type(defaults.delSetting)~='function' or type(defaults.flush)~='function' then return end
        local expected=copy(state.values)
        local entries={{key='copt_h_page_margins',value={expected.l,expected.r}},
            {key='copt_t_page_margin',value=expected.t},{key='copt_b_page_margin',value=expected.b},
            {key='copt_sync_t_b_page_margins',value=expected.sync}}
        local confirm
        confirm=ConfirmBox:new{text=_('Save these margins and the top/bottom sync setting as KOReader defaults? They also apply to other books without their own settings.'),
            ok_text=_('Save defaults'),ok_callback=function()
                if not current() or state.confirm~=confirm then return end
                if state.pending or not same(read(config,typeset),expected) then
                    if type(host.showInfo)=='function' then host:showInfo(_('Page margins changed. Please try again.')) end
                    return
                end
                local captured=pcall(function() for _,entry in ipairs(entries) do entry.previous=defaults:readSetting(entry.key) end end)
                if not captured then
                    if type(host.showInfo)=='function' then host:showInfo(_('Could not save margin defaults.')) end
                    return
                end
                local ok=pcall(function()
                    for _,entry in ipairs(entries) do defaults:saveSetting(entry.key,entry.value) end
                    assert(defaults:flush()~=nil)
                end)
                if not ok then
                    for _,entry in ipairs(entries) do pcall(function()
                        if entry.previous==nil then defaults:delSetting(entry.key)
                        else defaults:saveSetting(entry.key,entry.previous) end
                    end) end
                    pcall(defaults.flush,defaults)
                    if type(host.showInfo)=='function' then host:showInfo(_('Could not save margin defaults.')) end
                elseif type(host.showTransientInfo)=='function' then host:showTransientInfo(_('Margin defaults saved.'),2) end
            end}
        local onclose=confirm.onCloseWidget
        confirm.onCloseWidget=function(instance,...)
            if state.confirm==instance then state.confirm=nil end
            if onclose then return onclose(instance,...) end
        end
        state.confirm=confirm
        if not pcall(UI.show,UI,confirm) then state.confirm=nil;pcall(UI.close,UI,confirm) end
    end
    local ok,dialog=pcall(function() return ButtonDialog:new{title=title(),buttons={
        {{id='margin_horizontal_down',text=_('L/R −5'),callback=function() adjust(true,-5) end},
         {id='margin_horizontal_up',text=_('L/R +5'),callback=function() adjust(true,5) end}},
        {{id='margin_vertical_down',text=_('T/B −5'),callback=function() adjust(false,-5) end},
         {id='margin_vertical_up',text=_('T/B +5'),callback=function() adjust(false,5) end}},
        {{id='margin_compact',text=_('Compact'),callback=function() preset('compact') end},
         {id='margin_standard',text=_('Standard'),callback=function() preset('standard') end},
         {id='margin_wide',text=_('Wide'),callback=function() preset('wide') end}},
        {{id='margin_default',text=_('Save margin defaults'),enabled=type(G_reader_settings)=='table',callback=save_default}},
        {{id='margin_back',text=_('Back'),callback=function() state.stop(true) end}},
    }} end)
    if not ok or not dialog then state.stop(false);return false end
    state.dialog=dialog
    local onclose=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if state.dialog==instance then state.dialog=nil;state.stop(true) end
        if onclose then return onclose(instance,...) end
    end
    if not pcall(UI.show,UI,dialog) then state.stop(false);return false end
    return true
end
return M
