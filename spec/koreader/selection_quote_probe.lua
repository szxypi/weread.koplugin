-- Private source only through captured pipes; no network, files or screenshots.
require('ffi').log=function() end
require('setupkoenv');package.path='/source/?.lua;'..package.path
local json=require('json');local raw=assert(io.stdin:read(4*1024*1024+1));assert(#raw<=4*1024*1024)
local input=json.decode(raw);local results={};local Quote=require('weread.lib.selection_quote')
for _i,selection in ipairs(input.selections) do
    local value,reason=Quote.project(input.raw,selection.first,selection.last,selection.text)
    results[#results+1]=value or {error=reason}
end
io.write('\nWEREAD_SELECTION_QUOTE_RESULT='..json.encode(results)..'\n')
