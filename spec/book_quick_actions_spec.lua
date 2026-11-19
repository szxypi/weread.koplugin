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
print('PASS: book quick actions ('..checks..' checks)')
