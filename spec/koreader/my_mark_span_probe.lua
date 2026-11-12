-- Private real quotes/source only cross captured pipes; no file or network.
require('ffi').log=function() end
require('setupkoenv');package.path='/source/?.lua;'..package.path
local Json=require('json');local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
local input=Json.decode(raw);local result={};local Span=require('weread.lib.my_mark_span')
for _i,row in ipairs(input.rows) do
    local value,reason=Span.prepare(input.raw,input.book_id,input.chapter_uid,row)
    result[#result+1]=value or {error=reason}
end
io.write('\nWEREAD_MY_MARK_SPAN_RESULT='..Json.encode(result)..'\n')
