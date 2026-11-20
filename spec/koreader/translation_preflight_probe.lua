-- Actual translated text is read from a private pipe, never disk or logs.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local raw=io.stdin:read(8*1024*1024+1)
local ok,result=pcall(function()
    assert(#raw<=8*1024*1024)
    local input=json.decode(raw);raw=nil
    assert(type(input.samples)=='table' and #input.samples>=1 and #input.samples<=2)
    local Model=require('weread.lib.translation')
    local output={samples=json.decode('[]')}
    for _,sample in ipairs(input.samples) do
        local profile=assert(Model.analyze(sample.html,'synthetic-scope',1))
        local book={blocks=profile.blocks,chapters={profile}}
        output.samples[#output.samples+1]={blocks=profile.blocks,pairs=#profile.pairs,relations=profile.relations,tags=profile.tags,
            translation_only_available=Model.translation_only_status(book).available,
            original_css=Model.css(book,'original')~=nil,bilingual_css=Model.css(book,'bilingual')~=nil,
            translation_css=Model.css(book,'translation')~=nil}
    end
    return output
end)
io.stdout:write('\nWEREAD_TRANSLATION_RESULT='..json.encode(ok and result or {error='model_failed'})..'\n')
os.exit(ok and 0 or 1)
