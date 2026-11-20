package.path='./?.lua;'..package.path
local queue={}
package.preload['ui/uimanager']=function() return {
    show=function() end,
    close=function(_self,dialog) if dialog.onCloseWidget then dialog:onCloseWidget() end end,
    nextTick=function(_self,callback) queue[#queue+1]=callback end,
} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_self,options) return options end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
package.preload['weread.lib.protocol']=function() return {is_mp_book=function(id) return tostring(id):match('^MP_WXS_')~=nil end} end
package.preload['weread.lib.shelf_membership_write']=function() return {book_id=function(id)
    return id:match('^[1-9]%d*$') and #id<=20 and id or nil
end} end
package.preload['weread.ui.shelf_membership_write']=function() return {open=function(host,id,_resolving,title) host.membership=id;host.saved_title=title end} end
package.preload['weread.ui.finish_change']=function() return {open=function(host,id) host.finished=id end} end
local Quick=require('weread.ui.book_quick_actions')
local Popup=require('weread.ui.shelf_popup')
local function flush() while #queue>0 do table.remove(queue,1)() end end
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    queue={}
    local current=true
    local owner={}
    local host={}
    function host:startBookReading(book) self.read=book end
    function host:showBookRecord(book) self.detail=book end
    function host:showShelfState(id) self.status=id end
    return host,owner,function() return current end,function() current=false end
end
local book={bookId='42',title='Test'}
for index,key in ipairs({'read','detail','status'}) do
    local host,owner,current=fixture()
    expect(Quick.open(host,owner,book,current),'valid book menu did not open')
    local dialog=owner._shelf_popup
    dialog.buttons[index][1].callback();flush()
    expect(host[key]==(key=='status' and '42' or book) and not owner._shelf_popup,'wrong action or book')
    dialog.buttons[index][1].callback();flush()
    expect(not owner._shelf_popup,'repeated callback reopened menu')
end
for _,event in ipairs({'dismissed','replaced','closed','account'}) do
    local host,owner,current,revoke=fixture()
    Quick.open(host,owner,book,current)
    local dialog=owner._shelf_popup
    dialog.buttons[1][1].callback()
    local replacement
    if event=='dismissed' then Popup.close(owner)
    elseif event=='replaced' then replacement={};Popup.show(owner,replacement)
    elseif event=='closed' then owner._shelf_closed=true
    else revoke() end
    flush()
    expect(not host.read, 'stale book action ran after '..event)
    if replacement then expect(owner._shelf_popup==replacement,'stale action closed replacement') end
end
do
    local host,owner,current=fixture()
    local changing={bookId='42'}
    Quick.open(host,owner,changing,current)
    owner._shelf_popup.buttons[1][1].callback();changing.bookId='43';flush()
    expect(not host.read, 'changed book identifier was opened')
end
local host,owner,current=fixture()
expect(not Quick.open(host,owner,{bookId='MP_WXS_42'},current),'public account got book actions')
expect(not Quick.open(host,owner,{bookId='\n'},current),'invalid id got book actions')
expect(Quick.open(host,owner,book,current),'valid book menu missing')
local dialog=owner._shelf_popup
expect(not Quick.open(host,owner,book,current) and owner._shelf_popup==dialog,'second hold replaced active menu')
local function by_label(menu,label)
    for _,row in ipairs(menu.buttons) do for _,button in ipairs(row) do
        if button.text==label then return button end
    end end
end
local function managed(present)
    local h,o,c,revoke=fixture()
    h.client={};h.shelf_membership={};h.library_db={open=function() end,accountKey=function() return 'owner' end,
        getShelfStatus=function() return {present=present} end}
    function h:showShelfState(id)
        self.status=id;self._shelf_state_menu={};Popup.show(o,self._shelf_state_menu)
        return true
    end
    return h,o,c,revoke
end
for _,entry in ipairs({{'Change cloud membership','membership'},{'Change finished mark','finished'}}) do
    local h,o,c=managed(true)
    expect(Quick.open(h,o,book,c),'managed menu missing')
    local button=assert(by_label(o._shelf_popup,entry[1]));button.callback();flush()
    expect(h[entry[2]]=='42' and h.status=='42' and o._shelf_popup==h._shelf_state_menu,
        'shortcut did not open its owned status and controller')
    if entry[2]=='membership' then expect(h.saved_title=='Test','selected title was not passed to membership flow') end
    button.callback();flush();expect(h[entry[2]]=='42','stale shortcut ran again')
end
do
    local h,o,c=managed(false);Quick.open(h,o,book,c)
    expect(by_label(o._shelf_popup,'Change cloud membership') and not by_label(o._shelf_popup,'Change finished mark'),
        'off-shelf book offered finished-mark change')
    Popup.close(o);h.library_db.accountKey=function() return nil end;Quick.open(h,o,book,c)
    expect(not by_label(o._shelf_popup,'Change cloud membership') and not by_label(o._shelf_popup,'Change finished mark'),
        'guest was offered account-specific writes')
end
do
    local h,o,c,revoke=managed(true);Quick.open(h,o,book,c)
    by_label(o._shelf_popup,'Change finished mark').callback();revoke();flush()
    expect(not h.finished and not h.status,'stale shortcut opened a controller')
end
do
    local h,_,c=managed(true);local existing={};h._shelf_state_menu=existing
    expect(not Quick.change(h,'42','weread.ui.finish_change',c), 'shortcut replaced an active status flow')
    expect(h._shelf_state_menu==existing and not h.status and not h.finished,'duplicate activation cancelled a status flow')
end
do
    local h,o,c=fixture();local calls=0
    expect(Quick.open(h,o,book,c,function() calls=calls+1 end),'local-group shortcut did not open')
    local shortcut=o._shelf_popup;local button=assert(by_label(shortcut,'Local groups for this book'))
    button.callback();flush();expect(calls==1 and not o._shelf_popup,'local-group shortcut did not run once')
    button.callback();flush();expect(calls==1,'dismissed local-group shortcut ran twice')
end
for _,event in ipairs({'account','book'}) do
    local h,o,c,revoke=fixture();local selected={bookId='42'};local calls=0
    Quick.open(h,o,selected,c,function() calls=calls+1 end)
    by_label(o._shelf_popup,'Local groups for this book').callback()
    if event=='account' then revoke() else selected.bookId='43' end
    flush();expect(calls==0,'stale local-group shortcut ran after '..event)
end
print('PASS: book quick actions ('..checks..' checks)')
