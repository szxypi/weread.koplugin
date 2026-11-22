package.path='./?.lua;'..package.path
package.preload['ui/uimanager']=function()return {close=function(_self,menu)if menu.onCloseWidget then menu:onCloseWidget()end end}end
package.preload['weread.lib.plugin_util']=function()return {tr=function(text)return text end}end
package.loaded['weread.ui.finish_offline']={get=function()end,cancel_dialog=function()end}
package.loaded['weread.ui.membership_offline']={get=function()end,cancel_dialog=function()end}
package.loaded['weread.ui.finish_change']={pending=function()end}
local pending,opened=nil,nil
package.loaded['weread.ui.shelf_flag_change']={pending=function()return pending end,
    open=function(_host,id,resolving,kind)opened={id=id,resolving=resolving,kind=kind}end}
local State=require('weread.ui.shelf_state');local checks=0
local function expect(value,label)checks=checks+1;assert(value,label)end
local account='a'
local host={client={},library_db={open=function()end,accountKey=function()return account end,
    getShelfStatus=function()return {present=true,book={bookId='41',secret=0,finishReading=0}}end},
    showList=function(_self,_title,items)return {item_table=items}end}
local function row(menu,label)
    for _,item in ipairs(menu.item_table) do if item.text==label then return item end end
end
State.show(host,'41');local menu=host._shelf_state_menu
expect(row(menu,'Pinned').mandatory=='Not provided','missing pin inferred as false')
expect(row(menu,'Change cloud pin')~=nil,'cloud pin entry missing')
row(menu,'Change cloud pin').callback();expect(opened and opened.id=='41' and opened.kind=='pinned' and opened.resolving==false,'cloud pin routed incorrectly')
opened=nil;account='b';row(menu,'Change cloud pin').callback();expect(not opened,'stale account opened cloud pin')
account='a';pending={metadata={kind='pinned'}};State.show(host,'41');menu=host._shelf_state_menu
expect(row(menu,'Check pending cloud pin change') and not row(menu,'Check pending private-reading change'),'pin pending labeled private')
row(menu,'Check pending cloud pin change').callback();expect(opened and opened.resolving and opened.kind=='pinned','pin pending routed incorrectly')
pending={metadata={kind='private'}};State.show(host,'41');menu=host._shelf_state_menu
expect(row(menu,'Check pending private-reading change') and not row(menu,'Check pending cloud pin change'),'private pending labeled pin')
print('PASS: cloud pin shelf state routing ('..checks..' checks)')
