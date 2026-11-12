package.path='./?.lua;'..package.path
local queue={};local UI={scheduleIn=function(_self,delay,task) assert(delay>=.1);queue[#queue+1]=task end,
    unschedule=function(_self,task) for i=#queue,1,-1 do if queue[i]==task then table.remove(queue,i) end end end,
    close=function(_self,widget) widget.closed=true end}
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end} end
package.preload['weread.ui.shelf_popup']=function() return {close=function() end,redraw=function(_menu,task) task() end} end
package.preload['weread.lib.selection_reference']=function() return {} end
package.preload['weread.ui.thought_editor']=function() return {cancel=function() end} end
local actions={}
package.preload['weread.ui.mark_editor']=function() return {cancel=function() end,start=function(_host,_owner,operation)
    actions[#actions+1]=operation
end} end
package.preload['weread.lib.bookmark_reference']=function() return {
    capture_native=function(input) assert(input.chapters[1].chapterUid==2);return {bookmark=true,type=0,range='15',markText='Source preview'} end,
    valid=function(row,id) return row.bookmark and id=='41' end,
} end
package.preload['weread.lib.source_context']=function() return {
    location=function(document,mode) return {point=document.point,view_mode=mode} end,
    same_location=function(a,b) return a and b and a.point==b.point and a.view_mode==b.view_mode end,
    capture=function(document,id,location,options)
        assert(options.is_current() and location.point==document.point and id=='41')
        return {file=document.file,book_id=id,text='Source preview',point_offset=0}
    end,
} end
local Selection=require('weread.ui.selection_thought')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function fixture()
    queue={};local f={account='account',scope={},valid=true,cancels=0}
    local host={_reader_session_gen=1,discovery_epoch=2,ui={document={file='/cached.epub',point='a'},view={view_mode='page'},highlight={}},settings={},library_db={}}
    host.detectWeReadBook=function() return '41' end
    host.settings.get_auth_scope=function() return f.scope end
    host.settings.auth_scope_matches=function(_self,scope) return f.valid and f.scope==scope end
    host.library_db.accountKey=function() return f.account end
    host.library_db.getChapters=function() return {{chapterUid=2,chapterIdx=3}} end
    host.showList=function(_self,title,rows)
        f.title=title;return {item_table=rows,switchItemTable=function(self,_title,items) self.item_table=items end}
    end
    package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_self,task,done)
        f.task,f.done=task,done;return true
    end,cancel=function() f.cancels=f.cancels+1 end} end}
    return host,f
end
local function advance() local task=table.remove(queue,1);assert(task);task() end
local function find(owner,label)
    for _i,item in ipairs(owner.menu.item_table) do if item.text==label then return item end end
end
local host,f=fixture();expect(Selection.open_bookmark(host),'current-page action rejected');advance();f.done(f.task())
local owner=host._selection_thought_owner
expect(f.title=='Save cloud bookmark' and owner.reference and owner.bookmarks,'bookmark owner/reference missing')
expect(find(owner,'Save cloud bookmark') and find(owner,'Bookmark source preview') and not find(owner,'Write private thought'),'point exposed text-only actions')
local save=find(owner,'Save cloud bookmark').callback;save();expect(actions[1]=='bookmark_create','point used highlight operation')
host.ui.document.point='b';save();expect(#actions==1,'page change sent old bookmark');Selection.view_changed(host)
expect(not host._selection_thought_owner and owner.menu.closed,'page change did not close bookmark owner')
for _i,kind in ipairs({'document','page','mode','account','session','epoch','scope','translation','close'}) do
    host,f=fixture();expect(Selection.open_bookmark(host),'could not open new bookmark owner');advance();owner=host._selection_thought_owner
    if kind=='document' then host.ui.document={file='/other.epub',point='a'} elseif kind=='page' then host.ui.document.point='b'
    elseif kind=='mode' then host.ui.view.view_mode='scroll' elseif kind=='account' then f.account='other'
    elseif kind=='session' then host._reader_session_gen=2 elseif kind=='epoch' then host.discovery_epoch=3
    elseif kind=='scope' then f.valid=false elseif kind=='translation' then host._translation_mode='translation'
    else Selection.cancel(host) end
    f.done(f.task())
    expect(not host._selection_thought_owner and not owner.reference and f.cancels==1,'stale bookmark result applied after '..kind)
end
host,f=fixture();host.ui.highlight.selected_text={text='Active selection'}
expect(not Selection.open_bookmark(host) and not host._selection_thought_owner and f.cancels==0,'active selection reused as page origin')
host,f=fixture();host._translation_mode='translation';expect(not Selection.open_bookmark(host) and f.cancels==0,'translated page became original bookmark')
host,f=fixture();f.account=nil;expect(not Selection.open_bookmark(host),'logged-out page opened bookmark')
print('bookmark_ui_scope_spec: '..checks..' checks')
