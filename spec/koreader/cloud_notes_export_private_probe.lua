-- Private input/output only: no files, networking, screenshots or diagnostics.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local Model=require('weread.lib.cloud_notes_export')
local codec={json_decode=function(_self,value) return json.decode(value) end,
    json_encode=function(_self,value) return json.encode(value) end}
local input=json.decode(assert(io.read('*a')))
local function export(format)
    local chunks={}
    local result=Model.write(input,format,codec,function(value) chunks[#chunks+1]=value;return true end)
    return result,table.concat(chunks)
end
local json_result,json_text=export('json')
local md_result,md_text=export('markdown')
assert(json_result.count==md_result.count and json_result.bytes==#json_text and md_result.bytes==#md_text)
io.write('\nWEREAD_CLOUD_NOTES_EXPORT='..json.encode({result='PASS',count=json_result.count,json=json.decode(json_text),markdown=md_text}))
