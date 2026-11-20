-- Open both pages of the self-authored PDF in KOReader's native PDF engine.
require('setupkoenv')
local home,path=assert(os.getenv('KO_HOME')),assert(arg[1])
assert(home:match('^/dev/shm/') and path:match('^/dev/shm/'))
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local document=assert(require('document/documentregistry'):openDocument(path))
assert(document.provider=='mupdf' and document:getPageCount()==2)
for page=1,2 do
    local words=assert(document:getPageText(page));assert(#words>0)
    local tile=assert(document:renderPage(page,nil,1,0,1,1,true));assert(tile.bb)
end
local found=assert(document:findAllText('synthetic pdf page one',true,0,4));assert(found[1])
document:close();print('PASS: synthetic PDF rendered on both pages by MuPDF')
