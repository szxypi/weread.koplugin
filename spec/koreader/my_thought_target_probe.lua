-- Private input/output only through captured pipes; no files or networking.
require('ffi').log=function() end
require('setupkoenv');package.path='/source/?.lua;'..package.path
local json=require('json');local raw=assert(io.stdin:read(4*1024*1024+1));assert(#raw<=4*1024*1024)
local input=json.decode(raw);local result={};local Target=require('weread.lib.my_thought_target')
for _i,row in ipairs(input.rows) do
    local point,reason=Target.project(input.raw,input.book_id,input.chapter_uid,row)
    result[#result+1]=point or {error=reason}
end
io.write('\nWEREAD_MY_THOUGHT_TARGET_RESULT='..json.encode(result)..'\n')
