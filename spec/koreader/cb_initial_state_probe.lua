-- Private pipe projection; the output contains only fixed booleans.
require('setupkoenv')
local root=arg[1] or '/source';package.path=root..'/?.lua;'..package.path
local json=require('json')
local State=require('weread.lib.cb_initial_state')
local raw=assert(io.stdin:read('*a'));assert(#raw<=1024*1024)
local input=json.decode(raw);assert(type(input.samples)=='table' and #input.samples<=16)
local out={}
for _i,item in ipairs(input.samples) do
    local state=State.from(item.raw,item.book)
    if state then
        out[#out+1]={recognized=true,index_present=state.index_present,summary_present=state.summary_present,
            updated_present=state.updated_present}
    else out[#out+1]={recognized=false} end
end
io.stdout:write('\nWEREAD_CB_INITIAL_STATE='..json.encode(out)..'\n')
