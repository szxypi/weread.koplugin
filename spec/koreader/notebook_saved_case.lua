-- Verify the local-by-book view without depending on the cloud list.
return function(host,mode,catalog,counters,wait,tick)
    local UI=require('ui/uimanager')
    local Catalog=require('weread.ui.notebook_catalog')
    local Stored=require('weread.lib.notebook_catalog_store')
    local Notes=require('weread.lib.my_cloud_marks_store')
    local tr=require('weread.lib.plugin_util').tr
    local account=host.library_db:accountKey()
    local id='900099'
    local before=tonumber(counters[0])
    if mode=='live' then
        local books=host.settings:get('books',{})
        books[id]={book_id=id,title='Synthetic saved book',author='Local author',_library_account_key=account}
        host.settings:set('books',books);host.settings:flush()
        assert(host.library_db:putChapters(id,{{chapterUid='1',title='Synthetic cached chapter'}}))
        local reviews=host.client:json_decode('[]')
        reviews[1]={reviewId='saved-extra-review',content='Separate local thought',isPrivate=1}
        assert(Notes:new(host.library_db,host.client,'thoughts'):write{
            schema=1,book_id=id,fetched_at=1000,reviews=reviews})
    else
        local db=assert(host.library_db:open())
        db:exec("DELETE FROM profile_state WHERE name='notebook_catalog'")
        db:close()
    end
    assert(Catalog.show(host))
    local owner=assert(host._notebook_owner)
    assert((owner.value~=nil)==(mode=='live'))
    local function find(menu,key,value)
        for index,item in ipairs(menu.item_table) do
            if item[key]==value then menu:onGotoPage(menu:getPageNumber(index));return item end
        end
    end
    local menu=owner.menu
    menu:onMenuSelect(assert(find(menu,'text',tr('Browse saved notes by book'))))
    wait(function() return not owner.context end)
    local saved=assert(menu._shelf_popup)
    assert(saved.title==tr('Books with saved notes'))
    local count=0
    for _i,item in ipairs(saved.item_table) do if item.notebook_id==id then count=count+1 end end
    assert(count==1,'two saved categories did not merge into one book')
    local entry=assert(find(saved,'notebook_id',id))
    assert(entry.text=='Synthetic saved book' and entry.mandatory=='Local author')
    saved:onLeftButtonTap()
    local search=assert(saved._shelf_popup)
    search:setInputText('Local author');search.buttons[1][2].callback()
    assert(#saved.item_table==1 and saved.item_table[1].notebook_id==id)
    saved:onMenuSelect(saved.item_table[1])
    local choices=assert(saved._shelf_popup)
    assert(#choices.buttons==3)
    choices.buttons[2][1].callback()
    local opened=assert(host._my_marks_owner)
    assert(opened.id==id and opened.thoughts and not opened.context)
    local thought=assert(find(opened.menu,'my_note_id','saved-extra-review'))
    opened.menu:onMenuSelect(thought)
    assert(opened.menu._shelf_popup.text:find('Separate local thought',1,true))
    host:cancelMyCloudMarks()
    saved:onMenuSelect(saved.item_table[1])
    choices=assert(saved._shelf_popup)
    choices.buttons[3][1].callback()
    opened=assert(host._my_marks_owner)
    assert(opened.id==id and opened.bookmarks and not opened.context)
    local bookmark=assert(find(opened.menu,'my_note_id','saved-point-extra'),'bookmark without preview was lost')
    assert(bookmark.text_func()=='Synthetic cached chapter','bookmark did not use the indexed chapter title')
    UI:close(saved);tick()
    assert(not host._my_marks_owner and not menu._shelf_popup)
    assert(tonumber(counters[0])==before,'saved book browsing issued a request')
    Catalog.cancel(host)
    if mode=='reopen' then
        assert(Stored:new(host.library_db,host.client,account):write(catalog))
    end
end
