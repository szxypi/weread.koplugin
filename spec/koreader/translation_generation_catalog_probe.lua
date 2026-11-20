-- Catalog and owner stay in an in-memory pipe; output contains only projection.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json')
local ok,result=pcall(function()
    package.path=assert(arg[1])..'/?.lua;'..package.path
    local input=assert(io.stdin:read(4*1024*1024+1));assert(#input<=4*1024*1024)
    input=json.decode(input)
    local M=require('weread.lib.translation_generation_catalog')
    local member=M.membership(input.member)
    local catalog=M.catalog(input.raw,input.book_id,input.info)
    local rows={}
    for _,row in ipairs(catalog.chapters) do
        rows[#rows+1]={uid=row.uid,free_or_owned=row.free_or_owned,wordCount=row.wordCount,
            translateVersion=row.translateVersion,transWordCount=row.transWordCount,hasTranslated=row.hasTranslated}
    end
    return {member=member.paying,format=catalog.format,version=catalog.version,rows=rows}
end)
if not ok then io.write('{"result":"UNVERIFIED"}');os.exit(1) end
io.write(json.encode(result));io.flush()
