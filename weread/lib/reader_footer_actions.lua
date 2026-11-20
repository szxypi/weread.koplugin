-- Resolve KOReader's own status-bar menu actions without copying their logic.
local ko=require('gettext')
local M={}
local specs={
    all_at_once={section='Configure items',field='all_at_once'},
    progress_bar={section='Progress bar',field='disable_progress_bar',text='Show progress bar',invert=true},
    page_progress={section='Status bar items',field='page_progress'},
    percentage={section='Status bar items',field='percentage'},
    time={section='Status bar items',field='time'},
    chapter_time_to_read={section='Status bar items',field='chapter_time_to_read'},
    battery={section='Status bar items',field='battery'},
}
local function unique(rows,predicate)
    if type(rows)~='table' then return nil end
    local found
    for _,row in ipairs(rows) do
        if type(row)=='table' and predicate(row) then
            if found then return nil end
            found=row
        end
    end
    return found
end
local function label(row)
    if type(row.text)=='string' then return row.text end
    if type(row.text_func)=='function' then
        local ok,value=pcall(row.text_func)
        if ok and type(value)=='string' then return value end
    end
end
function M.inspect(footer)
    local settings=type(footer)=='table' and footer.settings
    if type(settings)~='table' or settings.disabled==true or type(footer.addToMainMenu)~='function'
        or type(footer.textOptionTitles)~='function' then return {} end
    local menu={}
    if not pcall(footer.addToMainMenu,footer,menu) then return {} end
    local status=type(menu.status_bar)=='table' and menu.status_bar.sub_item_table
    local sections={}
    for _,name in ipairs({'Configure items','Progress bar','Status bar items'}) do
        local translated=ko(name)
        local section=unique(status,function(row) return label(row)==translated end)
        sections[name]=section and section.sub_item_table or nil
    end
    local result={}
    for key,spec in pairs(specs) do
        local value=settings[spec.field]
        if value==nil or type(value)=='boolean' then
            local expected
            if spec.text then expected=ko(spec.text)
            else
                local ok,title=pcall(footer.textOptionTitles,footer,spec.field)
                if ok and type(title)=='string' then expected=title end
            end
            if expected then
                local row=unique(sections[spec.section],function(item)
                    return label(item)==expected and type(item.callback)=='function' and type(item.checked_func)=='function'
                end)
                if row then
                    local ok,checked=pcall(row.checked_func)
                    local want=spec.invert and value~=true or not spec.invert and value==true
                    local enabled=true
                    if type(row.enabled_func)=='function' then
                        local enabled_ok,allowed=pcall(row.enabled_func)
                        enabled=enabled_ok and allowed==true
                    elseif row.enabled==false then enabled=false end
                    if ok and type(checked)=='boolean' and checked==want and enabled then
                        result[key]={row=row,checked=checked,field=spec.field,invert=spec.invert}
                    end
                end
            end
        end
    end
    return result
end
function M.activate(footer,key)
    local action=M.inspect(footer)[key]
    if not action then return false end
    local settings=footer.settings
    local ok=pcall(action.row.callback)
    if not ok or footer.settings~=settings then return false end
    local value=settings[action.field]
    local checked=action.invert and value~=true or not action.invert and value==true
    return type(value)=='boolean' and checked~=action.checked
end
return M
