-- Native reader settings; changes go through KOReader's document font module.
local ButtonDialog=require('ui/widget/buttondialog')
local ConfirmBox=require('ui/widget/confirmbox')
local Menu=require('ui/widget/menu')
local UI=require('ui/uimanager')
local Context=require('weread.lib.reader_progress_context')
local util=require('weread.lib.plugin_util')
local _=util.tr
local M={}
local definitions={
    size={field='font_size',method='onSetFontSize',min=12,max=255,step=1},
    spacing={field='line_spacing',method='onSetLineSpace',min=50,max=200,step=5},
    weight={field='font_base_weight',method='onSetFontBaseWeight',min=-1,max=3,step=.25},
}
local function number(value)
    if type(value)~='number' or value~=value or value==math.huge or value==-math.huge then return nil end
    return value
end

function M.cancel(host)
    local state=host and host._weread_reader_typography
    if state then state.stop(false) end
end

function M.show(host)
    local snapshot=Context.capture(host)
    local ui=snapshot and snapshot.ui
    local document=snapshot and snapshot.document
    local font=ui and ui.font
    local config=font and font.configurable
    if not snapshot or type(font)~='table' or type(config)~='table'
        or document.info and document.info.has_pages==true then
        if host and type(host.showInfo)=='function' then host:showInfo(_('Reading settings are unavailable for this file.')) end
        return false
    end
    M.cancel(host)
    local state={snapshot=snapshot,font=font,config=config,values={},baseline={},pending={}}
    for key,def in pairs(definitions) do
        local value=number(config[def.field])
        if value and value>=def.min and value<=def.max and type(font[def.method])=='function' then
            state.values[key],state.baseline[key]=value,value
        end
    end
    if not next(state.values) and type(font.onSetFont)~='function' then
        if type(host.showInfo)=='function' then host:showInfo(_('Reading settings are unavailable for this file.')) end
        return false
    end
    host._weread_reader_typography=state
    local function current()
        if host._weread_reader_typography~=state or host.ui~=ui or ui.document~=document
            or document.file~=snapshot.file or ui.font~=font or host._reader_session_gen~=snapshot.session then return false end
        local db=host.library_db
        if db and type(db.accountKey)=='function' then
            local ok,account=pcall(db.accountKey,db)
            if not ok or account~=snapshot.account then return false end
        elseif snapshot.account~=nil then return false end
        local settings=host.settings
        if snapshot.scope then
            if not settings or type(settings.auth_scope_matches)~='function' then return false end
            local ok,match=pcall(settings.auth_scope_matches,settings,snapshot.scope)
            if not ok or match~=true then return false end
        elseif settings and type(settings.get_auth_scope)=='function' then
            local ok,scope=pcall(settings.get_auth_scope,settings)
            if not ok or scope~=nil then return false end
        end
        return true
    end
    local function title()
        local function display(key,format)
            local value=state.values[key]
            return value and string.format(format,value) or '–'
        end
        local face=type(font.font_face)=='string' and font.font_face~='' and font.font_face or '–'
        return util.T(_('Reading settings · current file\nFont: %1\nSize %2 · Line spacing %3% · Weight %4'),face,
            display('size','%.0f'),display('spacing','%.0f'),display('weight','%.2f'))
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
    local function flush()
        if state.apply_task then UI:unschedule(state.apply_task);state.apply_task=nil end
        if not current() then
            state.pending={}
            if host._weread_reader_typography==state then state.stop(false) end
            return false
        end
        local pending=state.pending;state.pending={}
        local success=true
        for _,key in ipairs({'size','spacing','weight'}) do
            if pending[key] then
                local def=definitions[key]
                local observed=number(config[def.field])
                local target=state.values[key]
                if observed~=state.baseline[key] then
                    success=false
                else
                    local ok,result=pcall(font[def.method],font,target)
                    observed=number(config[def.field])
                    if not ok or result==false or observed~=target then success=false end
                end
                state.values[key],state.baseline[key]=observed,observed
                if not current() then return false end
            end
        end
        if not success and type(host.showInfo)=='function' then host:showInfo(_('Could not apply reading settings.')) end
        schedule_refresh()
        return success
    end
    state.stop=function(apply)
        if host._weread_reader_typography~=state then return end
        if apply and next(state.pending) then flush() end
        host._weread_reader_typography=nil
        if state.apply_task then UI:unschedule(state.apply_task);state.apply_task=nil end
        if state.refresh_task then UI:unschedule(state.refresh_task);state.refresh_task=nil end
        if state.confirm then local confirm=state.confirm;state.confirm=nil;UI:close(confirm) end
        if state.menu then local menu=state.menu;state.menu=nil;UI:close(menu) end
        if state.dialog then local dialog=state.dialog;state.dialog=nil;UI:close(dialog) end
    end
    local function change(key,direction)
        if not current() or not state.values[key] then return end
        local def=definitions[key]
        local value=math.max(def.min,math.min(def.max,state.values[key]+direction*def.step))
        if value==state.values[key] then return end
        state.values[key]=value;state.pending[key]=true
        schedule_refresh()
        if state.apply_task then UI:unschedule(state.apply_task) end
        local task
        task=function()
            if state.apply_task~=task then return end
            state.apply_task=nil;flush()
        end
        state.apply_task=task;UI:scheduleIn(.4,task)
    end
    local function choose_font()
        if not current() or type(font.face_table)~='table' then return end
        if next(state.pending) then flush() end
        if not current() then return end
        local items,seen={},{}
        for _index,row in ipairs(font.face_table) do
            local id=type(row)=='table' and row.menu_item_id
            if type(id)=='string' and id~='' and #id<=512 and not seen[id] and type(row.callback)=='function' then
                local label=id
                if type(row.text_func)=='function' then
                    local ok,value=pcall(row.text_func)
                    if ok and type(value)=='string' and value~='' then label=value end
                end
                seen[id]=true
                local selected=row
                items[#items+1]={text=label,mandatory=id==font.font_face and '✓' or '',callback=function()
                    if not current() then return end
                    local menu=state.menu;state.menu=nil;if menu then UI:close(menu) end
                    local ok=pcall(selected.callback)
                    if not ok and type(host.showInfo)=='function' then host:showInfo(_('Could not apply reading settings.')) end
                    schedule_refresh()
                end}
                if #items>=512 then break end
            end
        end
        if #items==0 then
            if type(host.showInfo)=='function' then host:showInfo(_('No fonts are available.')) end
            return
        end
        local menu=Menu:new{title=_('Choose font'),item_table=items,items_per_page=8}
        local onclose=menu.onCloseWidget
        menu.onCloseWidget=function(instance,...)
            if state.menu==instance then state.menu=nil end
            if onclose then return onclose(instance,...) end
        end
        state.menu=menu
        if not pcall(UI.show,UI,menu) then state.menu=nil;pcall(UI.close,UI,menu) end
    end
    local function save_default()
        if not current() then return end
        if next(state.pending) and not flush() then return end
        if not current() then return end
        local defaults=G_reader_settings
        if type(defaults)~='table' or type(defaults.saveSetting)~='function'
            or type(defaults.readSetting)~='function' or type(defaults.delSetting)~='function'
            or type(defaults.flush)~='function' then return end
        local entries={}
        if type(font.font_face)=='string' and font.font_face~='' then
            entries[#entries+1]={key='cre_font',value=font.font_face}
        end
        for _,key in ipairs({'size','spacing','weight'}) do
            local value=state.values[key]
            if value then entries[#entries+1]={key='copt_'..definitions[key].field,value=value,field=definitions[key].field} end
        end
        if #entries==0 then return end
        local confirm
        confirm=ConfirmBox:new{text=_('Save these settings as KOReader defaults? They also apply to other books without their own settings.'),
            ok_text=_('Save defaults'),ok_callback=function()
                if not current() or state.confirm~=confirm then return end
                if next(state.pending) then
                    if type(host.showInfo)=='function' then host:showInfo(_('Reading settings changed. Please try again.')) end
                    return
                end
                for _index,entry in ipairs(entries) do
                    local observed=entry.field and config[entry.field] or font.font_face
                    if observed~=entry.value then
                        if type(host.showInfo)=='function' then host:showInfo(_('Reading settings changed. Please try again.')) end
                        return
                    end
                end
                local captured=pcall(function()
                    for _,entry in ipairs(entries) do entry.previous=defaults:readSetting(entry.key) end
                end)
                if not captured then
                    if type(host.showInfo)=='function' then host:showInfo(_('Could not save reading defaults.')) end
                    return
                end
                local ok=pcall(function()
                    for _,entry in ipairs(entries) do defaults:saveSetting(entry.key,entry.value) end
                    assert(defaults:flush()~=nil)
                end)
                if not ok then
                    for _,entry in ipairs(entries) do
                        pcall(function()
                            if entry.previous==nil then defaults:delSetting(entry.key)
                            else defaults:saveSetting(entry.key,entry.previous) end
                        end)
                    end
                    pcall(defaults.flush,defaults)
                    if type(host.showInfo)=='function' then host:showInfo(_('Could not save reading defaults.')) end
                elseif type(host.showTransientInfo)=='function' then host:showTransientInfo(_('Reading defaults saved.'),2) end
            end}
        local onclose=confirm.onCloseWidget
        confirm.onCloseWidget=function(instance,...)
            if state.confirm==instance then state.confirm=nil end
            if onclose then return onclose(instance,...) end
        end
        state.confirm=confirm
        if not pcall(UI.show,UI,confirm) then state.confirm=nil;pcall(UI.close,UI,confirm) end
    end
    local ok,dialog=pcall(function()
        return ButtonDialog:new{title=title(),buttons={
            {{id='typography_size_down',text=_('Smaller text'),enabled=state.values.size~=nil,callback=function() change('size',-1) end},
             {id='typography_size_up',text=_('Larger text'),enabled=state.values.size~=nil,callback=function() change('size',1) end}},
            {{id='typography_spacing_down',text=_('Tighter lines'),enabled=state.values.spacing~=nil,callback=function() change('spacing',-1) end},
             {id='typography_spacing_up',text=_('Wider lines'),enabled=state.values.spacing~=nil,callback=function() change('spacing',1) end}},
            {{id='typography_weight_down',text=_('Lighter text'),enabled=state.values.weight~=nil,callback=function() change('weight',-1) end},
             {id='typography_weight_up',text=_('Heavier text'),enabled=state.values.weight~=nil,callback=function() change('weight',1) end}},
            {{id='typography_font',text=_('Choose font'),enabled=type(font.face_table)=='table' and type(font.onSetFont)=='function',callback=choose_font}},
            {{id='typography_default',text=_('Save as global defaults'),enabled=type(G_reader_settings)=='table',callback=save_default}},
            {{id='typography_close',text=_('Close'),callback=function() state.stop(true) end}},
        }}
    end)
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
