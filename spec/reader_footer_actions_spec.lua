package.path='./?.lua;'..package.path
package.preload.gettext=function() return function(text) return 'KO:'..text end end
local Actions=require('weread.lib.reader_footer_actions')
local settings={disable_progress_bar=false,all_at_once=false,page_progress=true,percentage=true,time=true,
    chapter_time_to_read=false,battery=true}
local calls=0;local duplicate=false;local fail=false;local disabled=false
local footer={settings=settings}
function footer:textOptionTitles(key) return 'option:'..key end
function footer:addToMainMenu(menu)
    local function row(field,invert)
        return {text_func=function() return self:textOptionTitles(field) end,
            checked_func=function() return invert and self.settings[field]~=true or not invert and self.settings[field]==true end,
            enabled_func=function() return not disabled end,
            callback=function() calls=calls+1;if fail then error('synthetic error') end;self.settings[field]=not self.settings[field] end}
    end
    local progress=row('disable_progress_bar',true);progress.text='KO:Show progress bar';progress.text_func=nil
    local items={row('page_progress'),row('percentage'),row('time'),row('chapter_time_to_read'),row('battery')}
    if duplicate then items[#items+1]=row('percentage') end
    menu.status_bar={sub_item_table={{text='KO:Progress bar',sub_item_table={progress}},
        {text='KO:Status bar items',sub_item_table=items},{text='KO:Configure items',sub_item_table={row('all_at_once')}}}}
end
local actions=Actions.inspect(footer)
assert(actions.progress_bar and actions.progress_bar.checked and actions.percentage and actions.percentage.checked)
assert(actions.chapter_time_to_read and not actions.chapter_time_to_read.checked and calls==0)
assert(Actions.activate(footer,'progress_bar') and settings.disable_progress_bar and calls==1)
assert(Actions.activate(footer,'percentage') and not settings.percentage and calls==2)
duplicate=true;assert(not Actions.inspect(footer).percentage and not Actions.activate(footer,'percentage'));duplicate=false
disabled=true;assert(not Actions.inspect(footer).time and not Actions.activate(footer,'time'));disabled=false
fail=true;assert(not Actions.activate(footer,'time') and settings.time);fail=false
settings.disabled=true;assert(not next(Actions.inspect(footer)))
print('reader_footer_actions_spec: native menu resolution and guarded callbacks passed')
