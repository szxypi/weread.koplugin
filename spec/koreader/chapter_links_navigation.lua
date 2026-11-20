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
local Identity=require('weread.lib.book_file_identity')
local json=require('json')
local chapters={{chapterUid=1,chapterIdx=1,title='独立正文',files={'Text/body.xhtml'},wordCount=2000},
    {chapterUid=2,chapterIdx=2,title='独立注释',files={'Text/notes.xhtml'},wordCount=2000},
    {chapterUid=3,chapterIdx=3,title='独立资料',files={'Text/资料 100%.xhtml'},wordCount=2000},
    {chapterUid=4,chapterIdx=4,title='按需下载章',files={'Text/chapter4.xhtml'},wordCount=2000}}
local book={bookId='900001',title='独立章节原生导航',bookVersion=7,wordCount=12000,cache_dir=evidence .. '/cache'}
local body='<p>正文<a id="ref" epub:type="noteref" href="notes.xhtml#%E4%B8%AD">[1]</a> '
    .. '<a href="notes.xhtml#literal%252A">百分号</a> '
    .. '<a href="%E8%B5%84%E6%96%99%20100%25.xhtml#资料">中文文件</a> '
    .. '<a href="chapter4.xhtml#note1">下载缺失章</a></p>'
    .. string.rep('<p>独立正文保持阅读位置，核对跨文件返回。</p>',100)
local target='<aside id="&#x4E2D;" epub:type="footnote"><p>图注正文</p>'
    .. '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="60"><rect width="90" height="50" fill="black"/></svg>'
    .. '<a href="body.xhtml#ref">返回正文链接</a> <a href="#local">本章引用</a></aside>'
    .. string.rep('<p>注释原文。</p>',40) .. '<p id="literal%2A">百分号锚点</p><p id="local">本章目标</p>'
local path=Content.save_chapter_epub({},book,chapters[1],body,{},'',Identity.capture(book))
local target_path=Content.save_chapter_epub({},book,chapters[2],target,{},'',Identity.capture(book))
local reference_path=Content.save_chapter_epub({},book,chapters[3],'<p id="资料">引用资料</p>',{},'',Identity.capture(book))
local settings=require('weread.lib.settings'):new()
book.cached_chapters={['1']=path,['2']=target_path,['3']=reference_path};book.chapters=chapters
settings:set('books',{['900001']=book})
assert(Content.save_catalog_cache({json_encode=function(_self,value) return json.encode(value) end},settings,book,chapters))
local sync=settings:get('sync');sync.pull_on_open=false;sync.enabled=false;settings:set('sync',sync)
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false;settings:set('cache',cache)
settings:flush()
local function bytes(file)
    local stream=assert(io.open(file,'rb'));local data=stream:read('*a');stream:close();return data
end
local function restore(file,data)
    local stream=assert(io.open(file,'wb'));assert(stream:write(data));stream:close()
end
local saved_source,saved_target=bytes(path),bytes(target_path)
local reader,origin,first_target,downloaded_path
local history_count
local receipts={}
local function current()
    reader=ReaderUI.instance
    return reader and reader.document and reader.weread and reader.weread._chapter_links
end
local function arrived(file)
    if not current() or reader.document.file~=file then return false end
    if reader.weread._chapter_link_job or not reader.rolling.xpointer then return false end
    return true
end
local function tap(index)
    local links={}
    for _i,link in ipairs(reader.document:getPageLinks()) do
        if link.segments and #link.segments>0 then links[#links+1]=link end
    end
    local rect=assert(links[index],'missing visible link ' .. index).segments[1]
    local gesture={pos=Geom:new{x=math.floor((rect.x0+rect.x1)/2),y=math.floor((rect.y0+rect.y1)/2)}}
    assert(reader.link:getLinkFromGes(gesture));reader.link:onTap(nil,gesture)
end
local function backward() assert(reader.link:onGoBackLink(true)) end
local steps={function()
    reader=ReaderUI:new{dimen=Screen:getSize(),document=Registry:openDocument(path)}
    UIManager:show(reader);reader.rolling:onGotoPage(1)
end,function()
    assert(current(),'chapter hooks not attached')
    origin=reader.rolling.xpointer
    tap(1)
end,function()
    if not arrived(target_path) then return false end
    assert(reader.rolling.xpointer=='#_doc_fragment_0_ 中','cached target anchor mismatch')
    first_target=reader.rolling.xpointer;receipts.cached_native_tap=true
    UIManager:forceRePaint();Screen:shot(evidence .. '/chapter-link-target.png')
    backward()
end,function()
    if not arrived(path) then return false end
    assert(reader.rolling.xpointer==origin,'cross-file Back did not restore exact native point')
    receipts.cross_file_back_exact=true
    assert(reader.link:onGoForwardLink())
end,function()
    if not arrived(target_path) then return false end
    assert(reader.rolling.xpointer==first_target,'Forward did not restore target')
    receipts.cross_file_forward_exact=true
    tap(2)
end,function()
    assert(reader.document.file==target_path and reader.rolling.xpointer=='#_doc_fragment_0_ local','local link interrupted')
    backward()
end,function()
    assert(reader.document.file==target_path,'local history crossed file too soon')
    backward()
end,function()
    if not arrived(path) then return false end
    assert(reader.rolling.xpointer==origin);receipts.local_history_above_boundary=true
    tap(2)
end,function()
    if not arrived(target_path) then return false end
    assert(reader.rolling.xpointer=='#_doc_fragment_0_ literal%2A','literal percent decoded twice')
    receipts.percent_anchor_literal=true;backward()
end,function()
    if not arrived(path) then return false end
    assert(reader.rolling.xpointer==origin);tap(3)
end,function()
    if not arrived(reference_path) then return false end
    assert(reader.rolling.xpointer=='#_doc_fragment_0_ 资料','Unicode filename/anchor failed')
    receipts.unicode_filename_and_anchor=true;backward()
end,function()
    if not arrived(path) then return false end
    assert(reader.rolling.xpointer==origin);tap(4)
end,function()
    if not current() then return false end
    local saved=reader.weread.settings:get_book(book.bookId)
    downloaded_path=saved and saved.cached_chapters and saved.cached_chapters['4']
    if not downloaded_path or not arrived(downloaded_path) then return false end
    assert(reader.rolling.xpointer=='#_doc_fragment_0_ note1','downloaded actual anchor not opened')
    receipts.missing_chapter_real_downloader=true
    receipts.download_reverified_before_open=true;backward()
end,function()
    if not arrived(path) then return false end
    assert(reader.rolling.xpointer==origin);receipts.download_back_exact=true
    -- Native source href in the notes returns through the same verified path.
    tap(1)
end,function()
    if not arrived(target_path) then return false end
    tap(1)
end,function()
    if not arrived(path) then return false end
    assert(reader.rolling.xpointer=='#_doc_fragment_0_ ref');receipts.original_return_link=true
    -- A moving source cancels its own worker; a late result cannot open a file.
    reader.rolling:onGotoPage(1);tap(1);reader.rolling:onGotoPage(2)
end,function()
    assert(reader.document.file==path and not reader.weread._chapter_link_job,'movement failed to cancel link')
    receipts.movement_cancellation=true
    reader.rolling:onGotoPage(1);tap(1)
    require('weread.ui.chapter_links').cancel(reader.weread)
end,function()
    assert(reader.document.file==path and not reader.weread._chapter_link_job,'cancel opened target')
    receipts.explicit_cancellation=true
    local changed={bookId=book.bookId,title=book.title,bookVersion=8,cache_dir=book.cache_dir}
    Content.save_chapter_epub({},changed,chapters[2],target,{},'',Identity.capture(changed))
    tap(1)
end,function()
    if reader.weread._chapter_link_job then return false end
    assert(reader.document.file==path and reader.rolling.xpointer==origin,'conflicting target moved source')
    receipts.version_conflict_keeps_source=true
    restore(target_path,saved_target)
    while UIManager:getTopmostVisibleWidget() and UIManager:getTopmostVisibleWidget()~=reader do UIManager:close(UIManager:getTopmostVisibleWidget()) end
    tap(1)
end,function()
    if not arrived(target_path) then return false end
    history_count=#reader.link.location_stack
    Content.save_chapter_epub({},book,chapters[1],body .. '<p>更换的正文。</p>',{},'',Identity.capture(book))
    backward()
end,function()
    if reader.weread._chapter_link_job then return false end
    assert(reader.document.file==target_path and reader.rolling.xpointer=='#_doc_fragment_0_ 中','changed return source accepted old point')
    assert(#reader.link.location_stack==history_count,'failed Back consumed history boundary')
    receipts.changed_return_archive_rejected=true
    restore(path,saved_source)
    while UIManager:getTopmostVisibleWidget() and UIManager:getTopmostVisibleWidget()~=reader do UIManager:close(UIManager:getTopmostVisibleWidget()) end
    backward()
end,function()
    if not arrived(path) then return false end
    assert(reader.rolling.xpointer==origin);receipts.failed_back_preserves_retry=true
    assert(not reader.weread.progress_sync.verified,'link granted cloud verification')
    receipts.no_cloud_verification_grant=true
    UIManager:forceRePaint();Screen:shot(evidence .. '/chapter-link-return.png')
    reader:onClose();reader=nil
end}
local failure,index,started=nil,1,os.time()
local function advance()
    if not steps[index] then UIManager:quit();return end
    if os.time()-started>105 then failure='step timeout ' .. index;UIManager:quit();return end
    local ok,value=xpcall(steps[index],debug.traceback)
    if not ok then failure='step ' .. index .. ': ' .. value;UIManager:quit();return end
    if value~=false then index=index+1;started=os.time() end
    UIManager:scheduleIn(index==2 and 2 or 0.3,advance)
end
advance();UIManager:run();assert(not failure,failure)
assert(index>#steps,'standalone navigation stopped early')
receipts.result='PASS';receipts.synthetic_only=true;receipts.account_data_posts=0
local file=assert(io.open(evidence .. '/chapter-links-navigation-result.json','wb'))
assert(file:write(json.encode(receipts)));file:close()
print('PASS: standalone cached/downloaded chapter links, literal anchors, native Back/Forward and cancellation')
