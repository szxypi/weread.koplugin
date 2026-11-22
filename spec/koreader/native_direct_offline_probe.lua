-- Reopen a synthetic direct-source EPUB in a separate, network-blocked process.
require('ffi').log=function() end
require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
assert(dofile(arg[1]..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local home=assert(os.getenv('KO_HOME'));local path=assert(arg[2])
assert(path:sub(1,#home+1)==home..'/' and require('weread.lib.native_direct_path').contains({data_dir=home},path))
local doc=assert(require('document/documentregistry'):openDocument(path))
assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
local hits=assert(doc:findAllText('Native source integrated marker 1',false,0,8,false,0));assert(hits[1])
local Position=require('weread.lib.position_source')
local raw=doc:getDocumentFileContent(Position.meta_path('37'))
assert(not raw or raw=='','native-only file acquired Web coordinate metadata')
if arg[3]=='1' then
    local text=assert(doc:getDocumentFileContent('OEBPS/text/chapter.xhtml'))
    assert(text:find('部分图片暂不可用',1,true) or text:find('Some images could not be loaded',1,true))
    local image=require('weread.lib.native_missing_image')
    local bytes=assert(doc:getDocumentFileContent('OEBPS/images/eink-'..require('weread.lib.crypto').sha256_hex(image)..'.png'))
    assert(bytes==image);local bitmap=assert(require('ui/renderimage'):renderImageData(bytes,#bytes,false,32,32))
    assert(bitmap:getWidth()>0 and bitmap:getHeight()>0);bitmap:free()
end
local settings={data_dir=home,cache_dir=home,get=function(_,key,default)
    if key=='books' then return {['42']={cached_file=path}} end
    return default
end}
local host={ui={document=doc},settings=settings}
assert(not require('weread.lib.reader_lifecycle').detectWeReadBook(host),'native-only file acquired sync identity')
local report=setmetatable({settings=settings,get_document=function() return doc end,detect_book=function() return '42' end,
    _config=function() return {mode='manual',book_id='42'} end},require('weread.lib.read_report'))
local id,_,reason=report:resolve_target();assert(not id and reason=='native_direct_local_only')
doc:close()
print('WEREAD_DIRECT_OFFLINE='..require('json').encode{ok=true,network_blocked=true,web_coordinates=false,
    manual_time_blocked=true,missing_images=arg[3]=='1' and 1 or 0})
