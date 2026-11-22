-- Private source token enters through stdin; no screenshots or content output.
require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
assert(dofile(assert(arg[2])..'/spec/koreader/offline_network_guard.lua')())
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
assert(type(input.token)=='string' and #input.token>=6 and #input.token<=128)
local settings={data_dir=home,cache_dir=home,get=function(_,_,default) return default end}
assert(require('weread.lib.native_direct_path').contains(settings,input.path))
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local doc=assert(require('document/documentregistry'):openDocument(input.path))
assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
local hits=assert(doc:findAllText(input.token,false,0,8,false,0));assert(hits[1])
local raw=doc:getDocumentFileContent(require('weread.lib.position_source').meta_path(input.uid))
assert(not raw or raw=='')
if input.missing_images>0 then
    local text=assert(doc:getDocumentFileContent('OEBPS/text/chapter.xhtml'))
    assert(text:find('部分图片暂不可用',1,true) or text:find('Some images could not be loaded',1,true))
    local placeholder=require('weread.lib.native_missing_image')
    local name='OEBPS/images/eink-'..require('weread.lib.crypto').sha256_hex(placeholder)..'.png'
    local bytes=assert(doc:getDocumentFileContent(name));assert(bytes==placeholder)
    local bitmap=assert(require('ui/renderimage'):renderImageData(bytes,#bytes,false,32,32))
    assert(bitmap:getWidth()>0 and bitmap:getHeight()>0);bitmap:free()
end
assert(not require('weread.lib.reader_lifecycle').detectWeReadBook{ui={document=doc},settings=settings})
local report=setmetatable({settings=settings,get_document=function() return doc end,detect_book=function() return input.book_id end,
    _config=function() return {mode='manual',book_id=input.book_id} end},require('weread.lib.read_report'))
local id,_,reason=report:resolve_target();assert(not id and reason=='native_direct_local_only')
doc:close()
print('WEREAD_DIRECT_OWNER_OFFLINE='..json.encode{ok=true,network_blocked=true,web_coordinates=false,
    manual_time_blocked=true,missing_images=input.missing_images,warning_verified=true})
