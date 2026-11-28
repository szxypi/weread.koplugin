-- Synthetic media notes in the actual plugin/CREngine/ReaderLink runtime.
local repo, evidence = assert(arg[1]), assert(arg[2])
local home = assert(os.getenv('KO_HOME'))
require('setupkoenv')
io.stdout:setvbuf('no')
package.path = repo .. '/?.lua;' .. package.path
G_defaults = require('luadefaults'):open()
G_reader_settings = require('luasettings'):open(home .. '/settings.reader.lua')
for key, value in pairs({ language='zh_CN', color_rendering=false, footnote_link_in_popup=true,
    tap_to_follow_links=true, copt_font_size=24, extra_plugin_paths={home .. '/plugins'} }) do
    G_reader_settings:saveSetting(key, value)
end
require('gettext').changeLang('zh_CN')
require('ui/bidi').setup('zh_CN')
local Device = require('device')
require('document/canvascontext'):init(Device)
assert(require('weread.lib.mock_environment').save{
    enabled=true, host='127.0.0.1', port=assert(tonumber(os.getenv('WEREAD_MOCK_PORT'))),
})
local Loader = require('pluginloader')
Loader.enabled_plugins, Loader.disabled_plugins, Loader.loaded_plugins = {}, {}, {}
for _i, entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path = repo .. '/?.lua;' .. package.path
local UIManager = require('ui/uimanager')
local Screen = Device.screen
local Geom=require('ui/geometry')
local ReaderUI = require('apps/reader/readerui')
local Registry = require('document/documentregistry')
local Content = require('weread.lib.content')
local Task=require('weread.lib.chapter_link_worker')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local MemoryWorker=require('weread.lib.memory_worker')
local json=require('json')
local chapters={{chapterUid=191,title='独立正文',files={'Text/body.xhtml'}},
    {chapterUid=192,title='独立注释',files={'Text/notes.xhtml'}},
    {chapterUid=193,title='独立资料',files={'Text/资料 100%.xhtml'}}}
local book={bookId='990191',title='独立章节路径核对',bookVersion=7,cache_dir=evidence .. '/cache'}
local body='<p>正文<a id="ref" epub:type="noteref" href="notes.xhtml#%E4%B8%AD">[1]</a>'
    .. '<a href="../Text/notes.xhtml#%E4%B8%AD">另一链接</a>'
    .. '<a href="notes.xhtml#literal%252A">百分号</a>'
    .. '<a href="%E8%B5%84%E6%96%99%20100%25.xhtml#资料">中文文件</a></p>'
local target='<aside id="&#x4E2D;" epub:type="footnote">注释正文</aside><p id="literal%2A">百分号锚点</p>'
local path=Content.save_chapter_epub({},book,chapters[1],body,{},'',Identity.capture(book))
local target_path=Content.save_chapter_epub({},book,chapters[2],target,{},'',Identity.capture(book))
local reference_path=Content.save_chapter_epub({},book,chapters[3],'<p id="资料">引用资料</p>',{},'',Identity.capture(book))
local settings=require('weread.lib.settings'):new()
settings:set('books',{['990191']={bookId=book.bookId,title=book.title,bookVersion=7,cache_dir=book.cache_dir,
    cached_chapters={['191']=path,['192']=target_path,['193']=reference_path},chapters=chapters}});settings:flush()
local reader,origin,identity,input,result,pending,observed
local codec={json_encode=function(_self,value) return json.encode(value) end,
    json_decode=function(_self,value) return json.decode(value) end}
local worker=MemoryWorker:new{scheduler=UIManager,codec=codec,max_bytes=128*1024}
local receipts={}
local function clone(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=clone(item) end;return out
end
local function start(value)
    result=nil;pending=true
    local document=reader.document
    assert(worker:start(function()
        -- Any accidental use of the inherited reader/ZIP wrapper fails in
        -- the child. The worker must open its own libarchive descriptor.
        document.getDocumentFileContent=function() error('inherited native archive access forbidden') end
        return Task.prepare(value)
    end,function(output) result=output;pending=false end))
end
local function wait()
    if pending then return false end
    assert(type(result)=='table','native child returned no result')
    assert(reader.document.file==path and reader.document:getXPointer()==origin,'preflight moved the reader')
    return true
end
local saved_source,saved_target
local function bytes(file)
    local stream=assert(io.open(file,'rb'));local data=stream:read('*a');stream:close();return data
end
local function restore(file,data)
    local stream=assert(io.open(file,'wb'));assert(stream:write(data));stream:close()
end
local steps={function()
    reader=ReaderUI:new{dimen=Screen:getSize(),document=Registry:openDocument(path)}
    UIManager:show(reader);reader.rolling:onGotoPage(1)
end,function()
    assert(reader.weread._current_weread_book_id==book.bookId)
    origin=reader.document:getXPointer();identity=Identity.read_document(reader.document,book.bookId)
    assert(identity.chapter_count==1 and identity.book_version==7)
    local links={}
    for _i,link in ipairs(reader.document:getPageLinks()) do
        if link.segments and #link.segments>0 then links[#links+1]=link end
    end
    local projected={}
    for index,link in ipairs(links) do
        local rect=link.segments[1]
        local actual=assert(reader.link:getLinkFromGes({pos=Geom:new{x=(rect.x0+rect.x1)/2,y=(rect.y0+rect.y1)/2}}))
        projected[index]={uri=link.uri,section=link.section,xpointer=actual.xpointer,from_xpointer=actual.from_xpointer}
    end
    local capture=assert(io.open(evidence .. '/synthetic-native-link-uris.json','wb'))
    capture:write(json.encode(projected));capture:close()
    assert(#links==4)
    observed=projected
    local Paths=require('weread.lib.book_link_paths')
    assert(Paths.native_uri_key(Task.RENDER_PATH,projected[1].xpointer)=='OEBPS/text/notes.xhtml#中')
    assert(Paths.native_uri_key(Task.RENDER_PATH,projected[2].xpointer)=='OEBPS/Text/notes.xhtml#中')
    saved_source,saved_target=bytes(path),bytes(target_path)
    input={book_id=book.bookId,chapter_uid='191',file=path,file_id=identity.file_id,
        chapters=chapters,cached_chapters={['191']=path,['192']=target_path,['193']=reference_path},native_uri=projected[1].xpointer}
    start(clone(input))
end,function()
    if not wait() then return false end
    assert(result.kind=='ready' and result.target_uid=='192' and result.anchor=='中' and result.anchor_verified)
    assert(result.source_file_id==identity.file_id and result.source_sha256==Crypto.sha256_hex(reader.document:getDocumentFileContent(Task.RENDER_PATH)))
    receipts.cached=true;receipts.independent_native_archive_worker=true
    local value=clone(input);value.native_uri=observed[2].xpointer;start(value)
end,function()
    if not wait() then return false end
    assert(result.kind=='ready' and result.anchor=='中');receipts.relative_uri_recovery=true
    local value=clone(input);value.native_uri=observed[3].xpointer;start(value)
end,function()
    if not wait() then return false end
    assert(result.kind=='ready' and result.anchor=='literal%2A');receipts.literal_percent_anchor_not_double_decoded=true
    local value=clone(input);value.native_uri=observed[4].xpointer;start(value)
end,function()
    if not wait() then return false end
    assert(result.kind=='ready' and result.anchor=='资料' and result.target_uid=='193');receipts.unicode_percent_filename=true
    local value=clone(input);value.cached_chapters['192']=nil;start(value)
end,function()
    if not wait() then return false end
    assert(result.kind=='needs_download' and result.target_uid=='192' and not result.anchor_verified)
    receipts.uncached_plan_not_anchor_proof=true
    local newer={bookId=book.bookId,title=book.title,bookVersion=8,cache_dir=book.cache_dir}
    Content.save_chapter_epub({},newer,chapters[2],target,{},'',Identity.capture(newer));start(clone(input))
end,function()
    if not wait() then return false end
    assert(result.kind=='unavailable' and result.reason=='version_mismatch');receipts.version_conflict_rejected=true
    restore(target_path,saved_target)
    Content.save_chapter_epub({},book,chapters[2],'<p id="中">甲</p><p id="中">乙</p>',{},'',Identity.capture(book))
    start(clone(input))
end,function()
    if not wait() then return false end
    assert(result.kind=='unavailable' and result.reason=='anchor_ambiguous');receipts.duplicate_anchor_rejected=true
    restore(target_path,saved_target)
    Content.save_chapter_epub({},book,chapters[1],body .. '<p>模拟替换的缓存。</p>',{},'',Identity.capture(book))
    start(clone(input))
end,function()
    if not wait() then return false end
    assert(result.kind=='unavailable' and result.reason=='file_changed')
    assert(Identity.read_document(reader.document,book.bookId).file_id==identity.file_id)
    receipts.source_replacement_rejected=true;receipts.old_reader_identity_not_rebound=true
    restore(path,saved_source)
    assert(bytes(path)==saved_source and bytes(target_path)==saved_target)
    receipts.original_archives_restored=true
    UIManager:forceRePaint();Screen:shot(evidence .. '/standalone-link-preflight.png')
    worker:cancel();reader:onClose();reader=nil
end}
local failure,index=nil,1
local function advance()
    if not steps[index] then UIManager:quit();return end
    local ok,value=xpcall(steps[index],debug.traceback)
    if not ok then failure=value;worker:cancel();UIManager:quit();return end
    if value~=false then index=index+1 end
    UIManager:scheduleIn(index==2 and 2 or 0.2,advance)
end
advance();UIManager:run();assert(not failure,failure)
assert(index>#steps,'standalone preflight stopped early')
receipts.result='PASS';receipts.synthetic_only=true;receipts.reader_position_exact=true
receipts.account_data_posts=0;receipts.navigation_or_download=false
local file=assert(io.open(evidence .. '/chapter-link-preflight-result.json','wb'))
assert(file:write(json.encode(receipts)));file:close()
print('PASS: independent standalone chapter link worker, actual native archives, cached/uncached plans and source/version/anchor conflicts; no navigation')
