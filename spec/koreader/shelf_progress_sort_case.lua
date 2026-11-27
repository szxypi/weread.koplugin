-- Real account-scoped SQLite, native menus and offline sort; synthetic only.
return function(plugin,mode,pump,evidence)
    local UI=require('ui/uimanager')
    local original_db,original_lookup=plugin.library_db,plugin.settings.book_lookup
    local original_filters=plugin.shelf_filters
    local original_shelf=plugin.settings:get('shelf')
    local original_sort,original_view,original_paged=original_shelf.sort_order,original_shelf.view_mode,original_shelf.paginated
    local vid='sort-account-a'
    local local_settings={data_dir=evidence,get=function(_,key,default)
        if key=='account' then return {user_vid=vid} end
        return default
    end}
    local db=require('weread.lib.library_db'):new(local_settings)
    plugin.library_db=db
    local owner=db:accountKey()
    local books={}
    for i=1,26 do books[i]={bookId=tostring(901000+i),title='合成进度书 '..i,isTop=i==7 and 1 or 0} end
    local archives={{archiveId=2,name='合成分组',bookIds={'901001','901003','901004','901006'}}}
    local snapshots={{book_id='901001',percent=0,fetched_at=1000},{book_id='901002',percent=85,fetched_at=1000},
        {book_id='901003',percent=50,fetched_at=1000},{book_id='901004',percent=50,fetched_at=1000},
        {book_id='901005',percent=100,fetched_at=1000},{book_id='901007',percent=60,fetched_at=1000},
        {book_id='901008',percent=0,fetched_at=1000}}
    if mode=='live' then
        assert(db:putShelfProgress(snapshots))
        vid='sort-account-b';assert(db:putShelfProgress({{book_id='901002',percent=7,fetched_at=1000}}));vid='sort-account-a'
    end
    local saved={['901001']={book_id='901001',pending_upload_account=owner,
        pending_upload_position={book_id='901001',percent=90}}}
    plugin.settings.book_lookup=function() return saved end
    plugin.shelf_filters={};plugin.shelf_group_key=nil;plugin.shelf_multi_groups={}
    local shelf=plugin.settings:get('shelf');shelf.view_mode='cover';shelf.paginated=true;shelf.sort_order='default'
    plugin.settings:set('shelf',shelf);plugin:applyShelfSnapshot(books,archives);plugin:showShelfView('books')
    local function select_sort(button)
        local old=assert(plugin.shelf_view);old.on_sort();local dialog=assert(old._shelf_popup)
        if button==8 and mode=='live' then
            UI:forceRePaint();require('device').screen:shot(evidence..'/progress-sort-menu.png')
        end
        assert(dialog.buttons[button] and dialog.buttons[button][1]);dialog.buttons[button][1].callback()
        pump(function() return plugin.shelf_view and plugin.shelf_view~=old end)
        return plugin.shelf_view
    end
    local view=select_sort(8)
    local expected={'901007','901005','901001','901002','901003','901004','901008','901006'}
    for i,id in ipairs(expected) do assert(view.books[i].bookId==id,'descending progress order or unknown placement changed') end
    assert(view.books[3]._shelf_progress==90 and view.books[3]._shelf_progress_local,'local pending progress lost priority')
    assert(view.page_count>1);UI:forceRePaint()
    if mode=='live' then require('device').screen:shot(evidence..'/progress-sort-result.png') end
    local order=view.books
    assert(db:putShelfProgress({{book_id='901002',percent=5,fetched_at=1001}}))
    view.on_page_changed(2);view=plugin.shelf_view
    assert(view.books==order and view.books[4].bookId=='901002','page change unexpectedly reordered live results')
    plugin:showShelfView('books');view=plugin.shelf_view
    assert(view.books[4].bookId=='901003','fresh view did not use latest cached progress')
    assert(db:putShelfProgress({{book_id='901002',percent=85,fetched_at=1000}}))
    view=select_sort(9)
    local ascending={'901007','901008','901003','901004','901002','901001','901005','901006'}
    for i,id in ipairs(ascending) do assert(view.books[i].bookId==id,'ascending progress order or stable ties changed') end
    local old=view;old.on_select_group('archive:2');pump(function() return plugin.shelf_view~=old end)
    view=plugin.shelf_view
    assert(#view.books==4 and view.books[1].bookId=='901003' and view.books[2].bookId=='901004'
        and view.books[3].bookId=='901001' and view.books[4].bookId=='901006','group lost progress sort')
    plugin:showShelfView('books','合成进度书 3')
    assert(#plugin.shelf_view.books==1 and plugin.shelf_view.books[1].bookId=='901003','progress sort broke group search')
    vid='sort-account-b';plugin.shelf_group_key=nil;plugin.shelf_multi_groups={};plugin:showShelfView('books')
    view=plugin.shelf_view
    assert(view.books[1].bookId=='901007' and view.books[2].bookId=='901002' and view.books[2]._shelf_progress==7,
        'another account inherited cached or pending progress')
    UI:forceRePaint();plugin:closeWeReadUI()
    plugin.settings.book_lookup=original_lookup;plugin.library_db=original_db;plugin.shelf_filters=original_filters
    shelf=plugin.settings:get('shelf');shelf.sort_order=original_sort;shelf.view_mode=original_view;shelf.paginated=original_paged
    plugin.settings:set('shelf',shelf);plugin.settings:flush()
    plugin.shelf_group_key=nil;plugin.shelf_multi_groups={}
    return true
end
