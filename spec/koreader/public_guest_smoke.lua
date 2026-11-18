-- Guest browsing through the real native search and book detail widgets.
return function(plugin,flush,paint)
    local settings=plugin.settings
    local original_account=settings:get('account',{})
    plugin:closeWeReadUI()
    settings:set('account',{});settings:flush()
    assert(not plugin.library_db:accountKey() and not settings:get_auth_scope())
    local original_start=plugin.qr_login.start
    local scans=0
    plugin.qr_login.start=function() scans=scans+1 end
    plugin:showBookstore()
    plugin.shelf_view.on_search()
    local dialog=assert(plugin.shelf_view._shelf_popup)
    dialog.getInputText=function() return '合成读物' end
    dialog.buttons[1][2].callback()
    flush()
    local state=assert(plugin.discovery_state)
    assert(state.kind=='search' and state.source_kind=='public' and #state.books==20
        and not state.account and scans==0,'guest normal search did not use public data')
    local first=state.books[1]
    first.categoryName='' -- A blank enriched field must not hide the public category.
    local cell=assert(plugin.shelf_view._item_rows[1])
    cell.callback()
    flush()
    local detail=assert(plugin._book_detail_view)
    assert(detail.data.title==first.title and detail.data.author_line==first.author and scans==0,
        'guest detail did not display public fields without login')
    assert(detail.data.intro==first._public_info.intro and detail.data.intro~='',
        'guest detail did not show public introduction')
    local category,publisher,rating=false,false,false
    for _,row in ipairs(detail.data.metadata) do
        for _,text in pairs(row) do
            category=category or text:find(first.category,1,true)~=nil
            publisher=publisher or text:find('合成出版社',1,true)~=nil
            rating=rating or text:find('8.6',1,true)~=nil
        end
    end
    assert(category and publisher and rating,'public category, publisher or rating not shown')
    assert(not plugin.book_metadata_context,'guest detail started authorized metadata fetch')
    paint('store-public-guest-detail')
    detail._refresh_button.callback()
    flush()
    assert(scans==1,'explicit metadata refresh did not request login')
    plugin:closeWeReadUI()
    plugin.qr_login.start=original_start
    settings:set('account',original_account);settings:flush()
    assert(plugin.library_db:accountKey())
    print('PASS: guest native search and book detail retain public metadata; explicit refresh requests login')
end
