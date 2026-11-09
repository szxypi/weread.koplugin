package.path='./?.lua;'..package.path
local state
package.preload['ui/uimanager']=function() return {show=function() end,close=function(_self,widget) if widget.onCloseWidget then widget:onCloseWidget() end end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end,T=function(text,...) local args={...};return (text:gsub('%%(%d+)',function(i) return tostring(args[tonumber(i)]) end)) end} end
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function(path)
    if path:find('legacy',1,true) then return nil end
    return {mode=state.link and 'link' or 'file',ino=state.replaced and 3 or 2,size=40,modification=1700000000,dev=1}
end} end
package.preload['weread.lib.content']=function() return {
    book_resolved_dir=function(_settings,_id,book) return book.cache_dir end,
    mp_article_cached_path=function(_settings,book) if not state.uncached then return book.cache_dir..'/article.html','identity' end end,
    mp_article_legacy_path=function() return '/legacy/article.html' end} end
package.preload['weread.ui.mp_download']=function() return {start=function(_host,_book,article,options) state.downloaded=article;state.preserve=options.preserve;return true end} end
local Versions=require('weread.lib.mp_cache_versions')
Versions.list=function() return {{path='/cache/article.html',current=true,info={mode='file',ino=2,size=40,modification=1700000000,dev=1}}} end
Versions.valid=function() return not state.invalid end
Versions.contains=function() return not state.invalid end
local Actions=require('weread.ui.mp_article_actions')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    state={account='one',books={MP_WXS_1={cache_dir='/cache'}}}
    local host={discovery_epoch=1,_reader_session_gen=2,ui={document={file='/book'}},
        settings={cache_dir='/all',get=function() return state.books end},library_db={accountKey=function() return state.account end},
        showInfo=function(_self,text) state.notice=text end,openFile=function(_self,path) state.opened=path end,
        showList=function(_self,title,rows) return {title=title,item_table=rows} end,
        showMPArticleExport=function() state.exported=true end,
        closeWeReadUI=function(self) Actions.cancel(self);self.discovery_epoch=self.discovery_epoch+1 end}
    local book={book_id='MP_WXS_1',title='Channel',cache_dir='/cache'}
    local article={reviewId='one',title='Test'};book.mp_articles={article}
    return host,book,article
end
local host,book,article=fixture()
expect(Actions.list(host,book,{article,article}) and #host._mp_cache_picker.item_table==1,'cache picker did not deduplicate identity')
host._mp_cache_picker.item_table[1].callback()
expect(#host._mp_actions_menu.item_table==5,'native cache actions missing')
host._mp_actions_menu.item_table[1].callback();expect(state.opened=='/cache/article.html','read cache action failed')
host._mp_actions_menu.item_table[4].callback();expect(state.exported,'export delegation missing')
host,book,article=fixture();Actions.refresh(host,book,article)
expect(host._mp_refresh_confirmation.text:find('reading position and notes',1,true),'refresh omitted retained history explanation')
host._mp_refresh_confirmation.ok_callback();expect(state.downloaded==article and state.preserve and not host._mp_refresh_confirmation,'refresh did not request immutable version')
for _,change in ipairs({'account','epoch','session','document','file','cache','record','book','replacement','identity'}) do
    host,book,article=fixture();Actions.refresh(host,book,article);local dialog=host._mp_refresh_confirmation
    if change=='account' then state.account='two' elseif change=='epoch' then host.discovery_epoch=10
    elseif change=='session' then host._reader_session_gen=10 elseif change=='document' then host.ui.document={file='/book'}
    elseif change=='file' then host.ui.document.file='/changed' elseif change=='cache' then host.settings.cache_dir='/changed'
    elseif change=='record' then state.books.MP_WXS_1.cache_dir='/moved' elseif change=='book' then book.cache_dir='/moved'
    elseif change=='replacement' then state.replaced=true else article.reviewId='changed' end
    dialog.ok_callback();expect(not state.downloaded,'stale confirmation downloaded: '..change)
end
host,book,article=fixture();Actions.refresh(host,book,article);local old=host._mp_refresh_confirmation
Actions.refresh(host,book,article);local fresh=host._mp_refresh_confirmation;old.ok_callback()
expect(host._mp_refresh_confirmation==fresh and not state.downloaded,'old confirmation affected replacement')
Actions.cancel(host);fresh.ok_callback();expect(not state.downloaded and not host._mp_refresh_confirmation,'cancelled confirmation restarted refresh')
host,book,article=fixture();expect(Actions.history(host,book,article),'history unavailable offline')
host._mp_versions_menu.item_table[1].callback();expect(state.opened=='/cache/article.html','history did not open saved path')
host,book,article=fixture();Actions.history(host,book,article);state.replaced=true
host._mp_versions_menu.item_table[1].callback();expect(not state.opened and state.notice,'replaced history file opened')
host,book,article=fixture();Actions.history(host,book,article);state.invalid=true
host._mp_versions_menu.item_table[1].callback();expect(not state.opened and state.notice,'invalid managed history path opened')
host,book,article=fixture();Actions.show(host,book,article);local row=host._mp_actions_menu.item_table[1];Actions.cancel(host);row.callback()
expect(not state.opened,'closed action menu remained active')
for _,change in ipairs({'uncached','link'}) do
    host,book,article=fixture();state[change]=true
    expect(not Actions.refresh(host,book,article) and not state.downloaded,'invalid cache refresh accepted')
end
print('PASS: native MP cache actions and stale confirmation guards ('..checks..' checks)')
