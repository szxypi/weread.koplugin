-- Synthetic-only TXT quote projection using KOReader's actual Lua runtime.
require('ffi').log=function() end
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json');local raw=io.stdin:read(4*1024*1024+1)
local ok,value=pcall(function()
    assert(#raw<=4*1024*1024);local input=json.decode(raw);raw=nil
    assert(type(input)=='table' and #input<=50)
    local project=require('weread.lib.selection_txt_quote').project
    local accepted,rejected=0,0
    for _i,row in ipairs(input) do
        local result=project(row.raw,row.first,row.last,row.text)
        if row.invalid then assert(not result);rejected=rejected+1
        else
            assert(result and result.range==row.range and result.abstract==row.quote and result.raw_bytes==#row.raw)
            accepted=accepted+1
        end
    end
    return {result='PASS',accepted=accepted,rejected=rejected}
end)
print('\nWEREAD_TXT_QUOTE='..json.encode(ok and value or {result='UNVERIFIED'}))
os.exit(ok and value.result=='PASS' and 0 or 1)
