-- Reopen the prior temporary EPUB with network disabled; no text is emitted.
require('ffi').log=function() end
require('setupkoenv')
package.loaded['weread.lib.logger']={info=function() end,warn=function() end,err=function() end,dbg=function() end}
package.path=assert(arg[1])..'/?.lua;'..package.path
local home=assert(os.getenv('KO_HOME'))
assert(os.getenv('WEREAD_OWNER_NATIVE_IMAGE_TMPFS')=='1' and home:match('^/dev/shm/'))
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
local json=require('json')
local ok,result=pcall(function()
    local file=assert(io.open(home..'/native-owner-state.json','rb'))
    local raw=assert(file:read(65537));file:close();assert(#raw<=65536)
    local state=json.decode(raw)
    assert(type(state)=='table' and type(state.path)=='string' and state.path:sub(1,#home+1)==home..'/'
        and type(state.assets)=='table' and #state.assets>0 and #state.assets<=2048)
    local network=0
    require('socket.http').request=function() network=network+1;error('offline request forbidden') end
    local Device=require('device');require('document/canvascontext'):init(Device)
    local doc=assert(require('document/documentregistry'):openDocument(state.path))
    assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
    assert(doc:getPageCount()>=1 and not require('weread.lib.position_source').read_document(doc,state.book_id,state.uid))
    local Crypto=require('weread.lib.crypto')
    for _,asset in ipairs(state.assets) do
        assert(type(asset.href)=='string' and asset.href:match('^images/eink%-[0-9a-f]+%.[a-z]+$'))
        local data=assert(doc:getDocumentFileContent('OEBPS/'..asset.href))
        assert(Crypto.sha256_hex(data)==asset.digest)
        local bitmap=assert(require('ui/renderimage'):renderImageData(data,#data,false,160,160))
        assert(bitmap:getWidth()>0 and bitmap:getHeight()>0);bitmap:free()
    end
    assert(network==0);doc:close()
    return {ok=true,offline_network=network,assets=#state.assets,web_coordinate_authority=false}
end)
io.stdout:write('\nWEREAD_NATIVE_OFFLINE_RESULT='..json.encode(ok and result or {ok=false})..'\n')
os.exit(ok and 0 or 1)
