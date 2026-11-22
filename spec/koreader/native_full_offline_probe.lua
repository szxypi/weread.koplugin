-- Open the previously downloaded book in a fresh process with network blocked.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local home=assert(os.getenv('KO_HOME'))
assert(os.getenv('WEREAD_OWNER_NATIVE_FULL_TMPFS')=='1' and home:match('^/dev/shm/'))
local json=require('json')
local ok,result=pcall(function()
    assert(dofile(arg[1]..'/spec/koreader/offline_network_guard.lua')())
    local file=assert(io.open(home..'/native-full-offline.json','rb'))
    local raw=assert(file:read(65537));assert(file:close());assert(#raw<=65536)
    local state=json.decode(raw)
    assert(type(state)=='table' and type(state.path)=='string' and state.path:sub(1,#home+1)==home..'/'
        and type(state.book_id)=='string' and type(state.chapters)=='table' and #state.chapters==2)
    G_reader_settings=require('luasettings'):wrap({})
    G_defaults=require('luadefaults'):open()
    local Device=require('device');require('document/canvascontext'):init(Device)
    local doc=assert(require('document/documentregistry'):openDocument(state.path))
    assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
    local Position=require('weread.lib.position_source')
    local Crypto=require('weread.lib.crypto')
    local images=0
    for _,chapter in ipairs(state.chapters) do
        local proof=assert(Position.read_document(doc,state.book_id,chapter.uid))
        assert(Crypto.sha256_hex(proof.raw)==chapter.raw_sha256)
        local hits=assert(doc:findAllText(chapter.search_token,false,0,8,false,0));assert(hits[1])
        if chapter.image then
            assert(chapter.image:match('^eink%-[0-9a-f]+%.[a-z]+$'))
            local data=assert(doc:getDocumentFileContent('OEBPS/images/'..chapter.image))
            assert(Crypto.sha256_hex(data)==chapter.image_sha256)
            local bitmap=assert(require('ui/renderimage'):renderImageData(data,#data,false,100,100))
            assert(bitmap:getWidth()>0);bitmap:free();images=images+1
        end
    end
    assert(images>0);doc:close()
    return {ok=true,chapters=#state.chapters,images=images,network_blocked=true}
end)
io.stdout:write('\nWEREAD_FULL_OFFLINE_RESULT='..json.encode(ok and result or {ok=false})..'\n')
os.exit(ok and 0 or 1)
