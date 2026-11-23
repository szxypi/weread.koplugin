-- Exercise the packaged quick menu and KOReader search on synthetic EPUBs.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
local scope=assert(os.getenv('WEREAD_TEST_SEARCH_SCOPE'))
assert(scope=='full' or scope=='chapter')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device')
require('document/canvascontext'):init(Device)
local Loader=require('pluginloader')
Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _index,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Content=require('weread.lib.content')
local settings=require('weread.lib.settings'):new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'))
local reopen=os.getenv('WEREAD_TEST_QUICK_REOPEN')=='1'
local chapters={{chapterUid=1,chapterIdx=1,title='合成第一章'},
    {chapterUid=2,chapterIdx=2,title='合成第二章'}}
local paragraphs={}
for i=1,240 do paragraphs[#paragraphs+1]='<p>合成段落'..i..'：这是用于测试原生正文搜索的普通文字。</p>' end
local body=table.concat(paragraphs)
local target=body..'<p>这行包含唯一目标 quartzneedle，供搜索定位。</p>'
local selected=scope=='full' and chapters or {chapters[1]}
local bodies=scope=='full' and {['1']=body,['2']=target} or {['1']=target}
local book,path
if reopen then
    book=assert(settings:get('books')['900001']);path=assert(book.cached_file)
else
    book={book_id='900001',bookId='900001',title='合成搜索测试',author='合成作者',chapters=chapters}
    path=Content.save_book_epub(settings,book,selected,bodies,scope)
    book.cached_file,book.cached_chapters=path,{['1']=path}
    if scope=='full' then book.cached_full_book=path end
    settings:set('books',{['900001']=book})
    settings:set('sync',{pull_on_open=false,upload_on_close=false})
    settings:flush()
end
local UI=require('ui/uimanager')
local reader=require('apps/reader/readerui'):new{
    dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(path),
}
UI:show(reader)
local function flush()
    UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
end
flush()
local plugin=assert(reader.weread)
local requests=0
plugin.client.request=function() requests=requests+1;error('search attempted network',0) end
reader.rolling:onGotoPercent(0);flush()
local before=reader.document:getCurrentPage()
assert(plugin:showEndOfBookDialog('900001'))
flush()
local quick=assert(UI:getTopmostVisibleWidget())
local I18n=require('weread.lib.i18n')
local search_button,store_button
for _row,buttons in ipairs(quick.buttons) do
    for _column,button in ipairs(buttons) do
        if button.text==I18n.tr('Search current file') then search_button=button end
        if button.text==I18n.tr('Search bookstore') then store_button=button end
    end
end
assert(search_button and search_button.enabled~=false and store_button)
UI:forceRePaint();Device.screen:shot(evidence..'/quick-search-menu.png')
search_button.callback();flush()
local input=assert(reader.search.input_dialog)
assert(UI:getTopmostVisibleWidget()==input)
input:setInputText('quartzneedle')
input.buttons[1][4].callback()
for _i=1,5 do flush() end
local after=reader.document:getCurrentPage()
assert(after>before and after>=math.floor(reader.document:getPageCount()*.85),
    'native search did not reach the target near the end of the document')
local anchor=assert(reader.document:getXPointer())
for _i=1,10 do
    local top=UI:getTopmostVisibleWidget()
    if not top or top==reader then break end
    UI:close(top);flush()
end
assert(plugin:showEndOfBookDialog('900001'));flush()
quick=assert(UI:getTopmostVisibleWidget());store_button=nil
for _row,buttons in ipairs(quick.buttons) do for _column,button in ipairs(buttons) do
    if button.text==I18n.tr('Search bookstore') then store_button=button end
end end
assert(store_button and store_button.enabled~=false);store_button.callback();flush()
local store=assert(plugin.shelf_view);local store_input=assert(store._shelf_popup)
assert(type(store_input.setInputText)=='function','bookstore search input not opened')
store_input.buttons[1][1].callback();plugin:closeWeReadUI();flush()
assert(reader.document:isXPointerInCurrentPage(anchor),'bookstore search changed the reader page')
assert(requests==0,'native search attempted a network request')
print('\nWEREAD_QUICK_SEARCH_RESULT='..require('json').encode({result='PASS',scope=scope,
    reopen=reopen,quick_menu=true,native_search=true,target_page_after_start=true,store_search=true,
    reader_page_preserved=true,requests=requests}))
os.exit(0)
