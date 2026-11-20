-- Private captured-pipe projection only. No credentials, network or files.
require('setupkoenv')
local root=arg[1] or '/source';package.path=root..'/?.lua;'..package.path
local json=require('json');local Model=require('weread.lib.cb_cloud_position')
local raw=assert(io.stdin:read('*a'));assert(#raw<=20*1024*1024)
local input=json.decode(raw);assert(type(input.samples)=='table' and #input.samples<=16)
local out={}
for _i,v in ipairs(input.samples) do out[#out+1]=Model.state(v.raw,v.book_id,v.chapters,v.channel) end
io.stdout:write('\nWEREAD_CB_CLOUD_POSITION='..json.encode(out)..'\n')
