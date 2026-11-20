package.path='./?.lua;'..package.path
local UI={show=function() end,close=function(_,view) if view.onCloseWidget then view:onCloseWidget() end end,
    nextTick=function(_,callback) callback() end}
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/inputdialog']=function() return {new=function(_,data)
    function data:getInputText() return self.input end;return data
end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end,T=function(value,...)
    local args={...};return (value:gsub('%%(%d+)',function(n) return tostring(args[tonumber(n)] or '') end))
end} end
local mark={schema=1,book_id='1',updated={{bookmarkId='m1',markText='Needle in original'}},chapters={}}
local thought={schema=1,book_id='2',reviews={{reviewId='t2',content='Another needle'}}}
local snapshots={marks={['1']=mark},thoughts={['2']=thought}}
package.preload['weread.lib.my_cloud_marks_store']=function() return {MAX_BOOKS=64,new=function(_,_,_,variant)
    local rows=snapshots[variant or 'marks'];return {list_ids=function() local ids={};for id in pairs(rows) do ids[#ids+1]=id end;return ids end,
        read=function(_,id) return rows[id] end}
end} end
local Search=require('weread.ui.notebook_search')
local function setup()
    local state={current=true,notices={},online_calls=0,cancelled=0}
    local owner={value={books={{bookId='1',title='First book'},{bookId='2',title='Second book'}}},menu={}}
    local host={settings={},client={},library_db={}}
    function host.settings:get_book() return nil end
    function host:showInfo(text) state.notices[#state.notices+1]=text end
    function host:showInputDialog(dialog) UI:show(dialog) end
    function host:showBusy(_,cancel) self.busy_message={cancel=cancel} end
    function host:closeBusy() self.busy_message=nil end
    function host:showList(title,items) local menu={title=title,item_table=items};state.result=menu;return menu end
    function host:showMyCloudMarks(id)
        state.opened=id;self._my_marks_owner={};self._my_marks_menu={item_table={{my_note_id='m1',callback=function() state.opened_note='m1' end}}}
    end
    function host:showMyCloudThoughts(id)
        state.opened=id;self._my_marks_owner={};self._my_marks_menu={item_table={{my_note_id='t2',callback=function() state.opened_note='t2' end}}}
    end
    package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_,task,callback)
        state.task,state.callback=task,callback;return true end,cancel=function() state.cancelled=state.cancelled+1 end} end}
    local function current() return state.current end
    return host,owner,state,current
end
local function start(host,owner,state,current,term)
    assert(Search.prompt(host,owner,current));local dialog=owner.menu._shelf_popup
    dialog.input=term;dialog.buttons[1][2].callback();assert(state.task and host.busy_message)
    state.callback(state.task());assert(not host.busy_message)
    return assert(state.result)
end
local host,owner,state,current=setup()
local menu=start(host,owner,state,current,'  NEEDLE ')
assert(#menu.item_table==5 and menu.item_table[1].select_enabled==false and menu.item_table[2].select_enabled==false and menu.item_table[3].select_enabled==false)
assert(menu.item_table[4].text=='Needle in original' and menu.item_table[4].mandatory:find('First book',1,true)
    and menu.item_table[5].text=='Another needle' and menu.item_table[5].mandatory:find('Second book',1,true))
assert(state.online_calls==0 and owner.menu._shelf_popup==menu)
menu.item_table[5].callback();assert(state.opened=='2' and state.opened_note=='t2' and owner.child==host._my_marks_owner)
menu.item_table[4].callback();assert(state.opened=='2','closed results callback opened stale note')
host,owner,state,current=setup();menu=start(host,owner,state,current,'needle')
snapshots.marks['1']=nil;menu.item_table[4].callback()
assert(not state.opened and #state.notices==1 and not owner.menu._shelf_popup,'removed cache triggered a stale open')
snapshots.marks['1']=mark
host,owner,state,current=setup();assert(Search.prompt(host,owner,current));local dialog=owner.menu._shelf_popup
dialog.input='   ';dialog.buttons[1][2].callback();assert(owner.menu._shelf_popup==dialog and #state.notices==1)
dialog.input='needle';dialog.buttons[1][2].callback();local late=state.callback
state.current=false;late(state.task());assert(not state.result and not host.busy_message,'changed owner accepted results')
host,owner,state,current=setup();assert(Search.prompt(host,owner,current));dialog=owner.menu._shelf_popup
dialog.input='needle';dialog.buttons[1][2].callback();late=state.callback;host.busy_message.cancel();late(state.task())
assert(not state.result and not owner.note_search_job and state.cancelled>0,'cancelled search returned late results')
local many={};for i=1,205 do many[i]={bookmarkId='i'..i,markText='matching note'} end
snapshots.marks['1']={updated=many,chapters={}};snapshots.thoughts['2']=nil
host,owner,state,current=setup();menu=start(host,owner,state,current,'matching')
local function find_row(view,label) for _,row in ipairs(view.item_table) do if row.text==label then return row end end end
assert(find_row(menu,'More results') and not find_row(menu,'Previous results'))
find_row(menu,'More results').callback();state.callback(state.task());menu=state.result
assert(find_row(menu,'Previous results') and not find_row(menu,'More results'))
local found={};for _,row in ipairs(menu.item_table) do if row.saved_note_id then found[#found+1]=row.saved_note_id end end
assert(#found==5 and found[1]=='i201' and found[5]=='i205')
find_row(menu,'Previous results').callback();state.callback(state.task());menu=state.result
assert(find_row(menu,'More results'))
find_row(menu,'More results').callback();many[10].markText='no match';state.callback(state.task())
assert(state.notices[#state.notices]=='Saved notes changed. Search again to see current results.' and not owner.menu._shelf_popup)
snapshots.marks['1']=mark;snapshots.thoughts['2']=thought
print('PASS: cross-book note search UI, saved scope and cancellation')
