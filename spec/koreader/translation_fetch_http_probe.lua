-- Real read-only adapter comparison. All private input/output stays in pipes.
require('ffi').log=function() end
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local raw=assert(io.stdin:read(1024*1024+1))
local phase='input'
local good,result=pcall(function()
    assert(#raw<=1024*1024)
    local input=json.decode(raw);raw=nil
    assert(type(input.samples)=='table' and #input.samples>=1 and #input.samples<=2)
    local cookies=input.cookies
    local settings={get=function(_self,key,default) if key=='cookies' then return cookies end;return default end,
        merge_set_cookie=function(_self,value) cookies=require('weread.lib.cookie').merge_set_cookie(cookies,value) end}
    phase='client';local client=require('weread.lib.client'):new(settings)
    local Content=require('weread.lib.content')
    local Fetch=require('weread.lib.translation_fetch')
    local Model=require('weread.lib.translation')
    local output={samples=json.decode('[]')}
    for _,sample in ipairs(input.samples) do
        local book={book_id=sample.book_id}
        local proxy=Fetch.client(client,book,sample.chapter_uid)
        phase='reader';Content.ensure_reader_state(proxy,book)
        phase='catalog'
        local chapters=Content.fetch_catalog(proxy,book);local selected
        for _,chapter in ipairs(chapters) do if tostring(chapter.chapterUid)==sample.chapter_uid then assert(not selected);selected=chapter end end
        assert(selected)
        phase='chapter';local source,receipt=Content.fetch_chapter_xhtml(proxy,settings,book,selected)
        assert(receipt and receipt.format=='web_xhtml')
        phase='analysis';local profile=assert(Model.analyze(source:match('<body[%s>]') and source or '<html><body>'..source..'</body></html>',sample.chapter_uid,1))
        output.samples[#output.samples+1]={sha256=require('weread.lib.crypto').sha256_hex(source),blocks=profile.blocks,pairs=#profile.pairs}
    end
    output.cookies=cookies
    return output
end)
local line=not good and tonumber(tostring(result):match(':(%d+):')) or nil
if line and line>10000 then line=nil end
io.stdout:write('\nWEREAD_TRANSLATION_FETCH_HTTP='..json.encode(good and result or {error='readonly_adapter_unavailable',stage=phase,line=line})..'\n')
os.exit(good and 0 or 1)
