-- Private input/output only through captured anonymous pipes; no files/network.
require('ffi').log=function() end
require('setupkoenv')
package.path='/source/?.lua;'..package.path
local json=require('json')
local input=assert(io.stdin:read(4*1024*1024+1));assert(#input<=4*1024*1024)
local value=json.decode(input);local result={}
local Target=require('weread.lib.my_mark_target')
for _i,row in ipairs(value.rows) do
    local point,reason=Target.project(value.raw,value.book_id,value.chapter_uid,row)
    result[#result+1]=point or {error=reason}
end
io.write('\nWEREAD_MY_MARK_TARGET_RESULT='..json.encode(result)..'\n')
