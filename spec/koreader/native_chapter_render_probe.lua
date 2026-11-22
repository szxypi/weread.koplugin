-- Synthetic native source, local EPUB creation and independent offline render.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local home,mode=assert(os.getenv('KO_HOME')),assert(arg[2])
assert(home:match('^/dev/shm/') and (mode=='create' or mode=='offline'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local Content=require('weread.lib.content')
local Identity=require('weread.lib.book_file_identity')
local Resources=require('weread.lib.native_chapter_resources')
local Position=require('weread.lib.position_source')
local png=require('mime').unb64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip5sAAAAASUVORK5CYII=')
local lines={}
for i=1,80 do lines[#lines+1]='<p>Native resource rendering marker '..i..' synthetic reading text.</p>' end
local body='<html><body><h1>Native resource fixture</h1><img src="../images/cover.png"/>'..table.concat(lines)..'</body></html>'
local css='p{line-height:1.4;background-image:url("../images/cover.png")}';local assets={{source='images/cover.png',data=png,media_type='image/png'}}
local source={source_channel='eink',coordinate_source_authoritative=false,is_text=false,body=body,css=css,assets=assets,unusable_resources=0,
    body_parts={{source='text/7.xhtml',data=body}},style_parts={{source='style/book.css',data=css}}}
local prepared=assert(Resources.prepare(source));assert(prepared.remote_references==0 and prepared.localized_references==2)
local href=assert(prepared.assets[1].href)
local chapter={chapterUid=7,chapterIdx=1,title='Synthetic chapter'}
local book={book_id='900001',bookVersion=7,title='Native synthetic',author='Fixture'}
local settings={cache_dir=home..'/cache',get=function(_self,_key,default) return default end}
local lfs=require('libs/libkoreader-lfs');if not lfs.attributes(settings.cache_dir) then assert(lfs.mkdir(settings.cache_dir)) end
local path_file=home..'/book-path'
local path
if mode=='create' then
    path=Content.save_chapter_epub(settings,book,chapter,prepared.xhtml,prepared.assets,prepared.css,Identity.capture(book),nil)
    local file=assert(io.open(path_file,'wb'));assert(file:write(path));assert(file:close())
else
    local file=assert(io.open(path_file,'rb'));path=assert(file:read('*a'));file:close()
end
assert(path:sub(1,#home+1)==home..'/')
local network=0
require('socket.http').request=function() network=network+1;error('offline network not allowed') end
local document=assert(require('document/documentregistry'):openDocument(path))
assert(document:loadDocument());document:setFontFace('Noto Sans');document:setFontSize(Device.screen:scaleBySize(24));document:render()
local hits=assert(document:findAllText('Native resource rendering marker 24',false,0,4,false,0))
assert(document:getPageCount()>=2 and hits[1] and hits[1].start)
assert(document:getDocumentFileContent('OEBPS/'..href)==png,'embedded image changed')
local rendered=assert(document:getDocumentFileContent('OEBPS/text/chapter.xhtml'))
local saved_css=assert(document:getDocumentFileContent('OEBPS/style.css'))
assert(rendered:find('../'..href,1,true) and saved_css:find('url("'..href..'")',1,true),'resource path not localized')
assert(not Position.read_document(document,'900001','7'),'native chapter was labelled as Web position source')
assert(network==0,'offline rendering attempted network')
document:close()
print('PASS: native resource EPUB '..mode..' rendered offline without Web position provenance')
