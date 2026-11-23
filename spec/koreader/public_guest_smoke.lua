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
    local function wait_metadata()
        local socket=require('socket');local deadline=socket.gettime()+20
        while plugin.book_metadata_context do
            assert(socket.gettime()<deadline,'public metadata deadline')
            flush();socket.sleep(.01)
        end
    end
    plugin:showSearch()
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
    flush();wait_metadata()
    local detail=assert(plugin._book_detail_view)
    assert(detail.data.title==first.title and detail.data.author_line:find(first.author,1,true) and scans==0,
        'guest detail did not display public fields without login')
    assert(detail.data.intro:find('自写合成简介',1,true),
        'guest detail did not show full public introduction')
    local saved=assert(settings:get_book(first.bookId))
    assert(saved.detail_source=='public' and saved.wordCount==12000 and not saved.secret and not saved.progress
        and not saved.bookVersion,'guest metadata saved non-display fields')
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
    flush();wait_metadata()
    assert(scans==0 and plugin._book_detail_view,'public metadata refresh unexpectedly requested login')
    local original_connected,original_require=plugin.isNetworkConnected,plugin.requireLogin
    local login_requests=0
    plugin.isNetworkConnected=function() return true end
    plugin.requireLogin=function() login_requests=login_requests+1;return false end
    local refreshed=assert(plugin._book_detail_view)
    local read_button
    for _,button in ipairs(refreshed._footer_actions) do
        if button.text==require('weread.lib.plugin_util').tr('▤ Read') then read_button=button end
    end
    assert(read_button);read_button.callback()
    assert(login_requests==1 and not plugin.book_reading_context,'guest reading bypassed login')
    plugin.isNetworkConnected,plugin.requireLogin=original_connected,original_require
    plugin:closeWeReadUI()
    plugin.qr_login.start=original_start
    settings:set('account',original_account);settings:flush()
    assert(plugin.library_db:accountKey())
    print('PASS: guest native search, full public detail and manual refresh without login')
end
