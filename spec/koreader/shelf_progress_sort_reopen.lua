-- A third process verifies the saved sort preference against persisted data.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
package.path=assert(os.getenv('WEREAD_SOURCE'))..'/?.lua;'..package.path
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local FM=require('apps/filemanager/filemanager');FM:showFiles(home);local plugin=assert(FM.instance.weread)
assert(plugin.settings:get('shelf').sort_order=='progress_desc','progress sort preference did not survive restart')
assert(plugin.settings:get('shelf').filter_reading=='progress_active','progress filter preference did not survive restart')
local requests=0
plugin.client.request=function() requests=requests+1;error('offline progress sort attempted HTTP',0) end
plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline
local filter_settings={data_dir=evidence,get=function(_,key,default)
    if key=='account' then return {user_vid='progress-filter-account-a'} end
    return default
end}
plugin.library_db=require('weread.lib.library_db'):new(filter_settings)
local filter_books={}
for i=1,9 do filter_books[i]={bookId=tostring(902000+i),title='合成筛选书 '..i,finishReading=0} end
filter_books[6].finishReading=1;filter_books[7].finishReading=nil
plugin.shelf_group_key=nil;plugin.shelf_multi_groups={};plugin:applyShelfSnapshot(filter_books,{})
plugin:showShelfView('books')
local filtered=assert(plugin.shelf_view)
assert(#filtered.books==2 and filtered.books[1].bookId=='902003' and filtered.books[2].bookId=='902002',
    'reopened filter did not apply persisted progress with the saved sort')
assert(requests==0,'reopened filter needed a network request')
local shelf=plugin.settings:get('shelf');shelf.filter_reading=nil;plugin.settings:set('shelf',shelf)
local local_settings={data_dir=evidence,get=function(_,key,default)
    if key=='account' then return {user_vid='sort-account-a'} end
    return default
end}
plugin.library_db=require('weread.lib.library_db'):new(local_settings)
local owner=assert(plugin.library_db:accountKey())
plugin.settings.book_lookup=function()
    return {['901001']={book_id='901001',pending_upload_account=owner,
        pending_upload_position={book_id='901001',percent=90}}}
end
local books={}
for i=1,26 do books[i]={bookId=tostring(901000+i),title='合成进度书 '..i,isTop=i==7 and 1 or 0} end
plugin.shelf_filters={};plugin:applyShelfSnapshot(books,{})
plugin.shelf_group_key=nil;plugin.shelf_multi_groups={};plugin:showShelfView('books')
local view=assert(plugin.shelf_view)
for index,id in ipairs({'901007','901005','901001','901002','901003','901004','901008','901006'}) do
    assert(view.books[index].bookId==id,'reopened progress sort did not use saved account data')
end
assert(view.books[3]._shelf_progress==90 and view.books[3]._shelf_progress_local and requests==0)
UI:forceRePaint();print('\nWEREAD_PROGRESS_SORT_REOPEN=PASS')
os.exit(0)
