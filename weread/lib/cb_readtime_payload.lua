-- A bounded current-session CB_ time payload. Source authorization and durable
-- dispatch remain the responsibility of the caller; this module is pure.
local Position=require('weread.lib.cb_position_payload')
local Protocol=require('weread.lib.protocol')
local M={}
function M.build(options,seconds)
    if type(seconds)~='number' or seconds~=seconds or seconds%1~=0 or seconds<1 or seconds>86400 then
        error('cb_readtime_payload/seconds',0)
    end
    local result=Position.build('position',options)
    result.rt=seconds
    result.s=nil
    result.s=Protocol.sign(Protocol.sorted_query(result))
    return result
end
return M
