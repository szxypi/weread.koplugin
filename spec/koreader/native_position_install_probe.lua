-- Synthetic runtime acceptance from the extracted production candidate.
require('ffi').log=function() end
require('setupkoenv')
local installed,source=assert(arg[1]),assert(arg[2])
package.path=installed..'/?.lua;'..source..'/?.lua;'..package.path
for _i,item in ipairs({{'native_position_protocol','body'},{'native_position_contract','valid'},
    {'native_position_store','advance'},{'native_position_task','run'},{'remote_progress','node'}}) do
    local module=require('weread.lib.'..item[1]);local path=debug.getinfo(assert(module[item[2]]),'S').source
    assert(path=='@'..installed..'/weread/lib/'..item[1]..'.lua','native_position/candidate_module')
end
dofile(source..'/spec/native_position_protocol_spec.lua')
dofile(source..'/spec/native_position_task_spec.lua')
print('PASS native_position_install_probe 5')
