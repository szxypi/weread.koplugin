-- Synthetic, offline native filter tests with real account-scoped SQLite.
return function(plugin,mode,pump,evidence)
    local UI=require('ui/uimanager')
    local old_db,old_indexes=plugin.library_db,plugin.settings.get_book_indexes
    local old_filters=plugin.shelf_filters
    local old_refresh,old_notice=plugin.refreshVisibleShelfProgress,plugin.showTransientInfo
    local shelf=plugin.settings:get('shelf')
    local old_sort,old_view,old_paged=shelf.sort_order,shelf.view_mode,shelf.paginated
    local old_reading,old_download=shelf.filter_reading,shelf.filter_download
    local vid='progress-filter-account-a'
    local settings={data_dir=evidence,get=function(_,key,default)
        if key=='account' then return {user_vid=vid} end
        return default
    end}
    local db=require('weread.lib.library_db'):new(settings);plugin.library_db=db
    local owner=db:accountKey()
    local books={}
    for i=1,9 do books[i]={bookId=tostring(902000+i),title='合成筛选书 '..i,finishReading=0} end
    books[6].finishReading=1;books[7].finishReading=nil
    local archives={{archiveId=2,name='合成筛选分组',bookIds={'902001','902002','902004'}}}
    if mode=='live' then
        assert(db:putShelfProgress({
            {book_id='902001',percent=0,exact_percent=0,fetched_at=1000},
            {book_id='902002',percent=0,exact_percent=0.25,fetched_at=1000},
            {book_id='902003',percent=21,fetched_at=1000},
            {book_id='902004',percent=0,fetched_at=1000}, -- ambiguous legacy zero
            {book_id='902006',percent=0,exact_percent=0,fetched_at=1000},
            {book_id='902007',percent=0,exact_percent=0,fetched_at=1000},
        }))
        vid='progress-filter-account-b'
        assert(db:putShelfProgress({{book_id='902002',percent=0,exact_percent=0,fetched_at=1000}}))
        vid='progress-filter-account-a'
    end
    local dir=evidence..'/progress-filter-book'
    local cached=dir..'/cached.epub'
    if mode=='live' then
        assert(require('weread.lib.book_store').save(plugin.settings,'902008',{book_id='902008',cache_dir=dir,
            cached_file=cached,
            pending_upload_account=owner,pending_upload_position={book_id='902008',percent=0.3}}))
        local file=assert(io.open(cached,'wb'));assert(file:write('Synthetic download'));assert(file:close())
    end
    plugin.settings.get_book_indexes=function() return {['902008']={cache_dir=dir}} end
    local redraw,notices
    plugin.refreshVisibleShelfProgress=function(_,_,_,_,options) redraw=options.on_redraw end
    plugin.showTransientInfo=function() notices=(notices or 0)+1 end
    plugin.shelf_filters={};plugin.shelf_group_key=nil;plugin.shelf_multi_groups={}
    shelf.view_mode='cover';shelf.paginated=true;shelf.sort_order='default'
    shelf.filter_reading=nil;shelf.filter_download=nil;plugin.settings:set('shelf',shelf)
    plugin:applyShelfSnapshot(books,archives);plugin:showShelfView('books')
    local function select_filter(button)
        local old=assert(plugin.shelf_view);old.on_filter();local dialog=assert(old._shelf_popup)
        if mode=='live' and button==4 then UI:forceRePaint();require('device').screen:shot(evidence..'/progress-filter-menu.png') end
        assert(dialog.buttons[button] and dialog.buttons[button][1]);dialog.buttons[button][1].callback()
        pump(function() return plugin.shelf_view and plugin.shelf_view~=old end)
        return plugin.shelf_view
    end
    local view=select_filter(4)
    assert(#view.books==1 and view.books[1].bookId=='902001','zero filter included ambiguous or finished entries')
    assert(notices==1 and plugin.settings:get('shelf').filter_reading=='progress_zero','filter choice was not persisted')
    UI:forceRePaint()
    if mode=='live' then require('device').screen:shot(evidence..'/progress-filter-zero.png') end
    view=select_filter(5)
    assert(#view.books==3 and view.books[1].bookId=='902002' and view.books[2].bookId=='902003'
        and view.books[3].bookId=='902008','positive filter lost fractional, legacy or local progress')
    assert(view._item_rows[1]._progress_badge_text=='<1%' and view._item_rows[3]._progress_badge_text=='本机 · <1%',
        'fractional progress is not labelled correctly on covers')
    UI:forceRePaint()
    if mode=='live' then require('device').screen:shot(evidence..'/progress-filter-reading.png') end
    plugin.shelf_filters.download='downloaded';plugin:showShelfView('books')
    view=plugin.shelf_view
    assert(#view.books==1 and view.books[1].bookId=='902008' and view.books[1]._cached
        and view.books[1]._shelf_progress_exact==0.3,'combined filters lost downloaded or pending progress')
    plugin.shelf_filters.download=nil;plugin:showShelfView('books');view=plugin.shelf_view
    local old=view;old.on_select_group('archive:2');pump(function() return plugin.shelf_view~=old end)
    view=plugin.shelf_view;assert(#view.books==1 and view.books[1].bookId=='902002','group filter lost the fractional book')
    local get_progress=db.getShelfProgress
    local queries={}
    db.getShelfProgress=function(self,ids)
        if #ids>0 then queries[#queries+1]=table.concat(ids,',') end
        return get_progress(self,ids)
    end
    plugin:showShelfView('books','合成筛选书 902002');view=plugin.shelf_view
    assert(#view.books==1 and view.books[1].bookId=='902002','search failed within a progress-filtered group')
    assert(#queries==1 and queries[1]=='902002','progress search read unrelated or repeated book records')
    view.on_sort()
    local Popup=require('weread.ui.shelf_popup')
    local dialog=assert(view._shelf_popup)
    assert(db:putShelfProgress({{book_id='902002',percent=0,exact_percent=0,fetched_at=1001}}))
    assert(redraw)()
    local progress_redraw=assert(view._shelf_redraw)
    local book=view.books[1]
    book.cover='https://cover.example.invalid/progress-filter.png'
    local cache=plugin:getShelfCoverCache()
    assert(cache:_ensureDir())
    local BB=require('ffi/blitbuffer')
    local bitmap=BB.new(32,48,BB.TYPE_BB8)
    bitmap:fill(BB.COLOR_GRAY)
    local original=cache.dir..'/'..cache:key(book)..'.png'
    bitmap:writePNG(original);bitmap:free()
    plugin:fetchVisibleShelfCovers(view,view.books,{mode='books',keyword='合成筛选书 902002',
        prepared_books=view.books,prepared_accounts={}})
    pump(function() return not plugin.shelf_cover_job and view._shelf_redraw~=progress_redraw end)
    local thumbnail=assert(cache:pathFor(book))
    assert(Popup.current(view,dialog) and plugin.shelf_view==view,
        'cover completion did not wait behind the open sort menu')
    Popup.close(view)
    pump(function() return plugin.shelf_view~=view end)
    view=plugin.shelf_view
    assert(#view.books==0,'visible progress update failed to refilter the old page')
    assert(view.empty_text and view.empty_text~='','empty filtered view lacks a recovery hint')
    assert(os.remove(thumbnail));book.cover=nil
    queries={}
    plugin:showShelfView('books','No matching book')
    assert(#plugin.shelf_view.books==0 and #queries==0,'empty search read progress for other books')
    db.getShelfProgress=get_progress
    assert(db:putShelfProgress({{book_id='902002',percent=0,exact_percent=0.25,fetched_at=1000}}))
    vid='progress-filter-account-b';plugin.shelf_group_key=nil;plugin:showShelfView('books')
    assert(#plugin.shelf_view.books==0,'another account inherited cached or local progress')
    vid='progress-filter-account-a';plugin:showShelfView('books')
    assert(#plugin.shelf_view.books==3,'returning account lost filtered progress')

    local first={bookId='903001',title='合成确认书 A',finishReading=0}
    local second={bookId='903002',title='合成确认书 B',finishReading=1}
    local finish_group={{archiveId=3,name='合成确认分组',bookIds={first.bookId,second.bookId}}}
    local function cache_finished(first_mark,second_mark)
        assert(db:cacheShelf({
            {bookId=first.bookId,title=first.title,finishReading=first_mark},
            {bookId=second.bookId,title=second.title,finishReading=second_mark},
        },finish_group))
    end
    cache_finished(0,1)
    shelf.filter_reading='unfinished';plugin.settings:set('shelf',shelf)
    plugin:applyShelfSnapshot({first,second},finish_group)
    plugin.shelf_group_key='archive:3';plugin:showShelfView('books')
    local Finish=require('weread.ui.finish_offline')
    view=plugin.shelf_view;assert(#view.books==1 and view.books[1]==first)
    cache_finished(1,1);Finish.refresh_view(plugin,first.bookId)
    assert(#plugin.shelf_view.books==0,'a confirmed finished book remained in the unfinished list')
    view=plugin.shelf_view;view.on_sort()
    cache_finished(1,0);Finish.refresh_view(plugin,second.bookId)
    assert(plugin.shelf_view==view and view._shelf_popup and #view.books==0)
    Popup.close(view);pump(function() return plugin.shelf_view~=view end)
    view=plugin.shelf_view
    assert(#view.books==1 and view.books[1]==second and plugin.shelf_group_key=='archive:3',
        'a formerly hidden book did not join its group after the finished flag changed')
    assert(db:putShelfProgress({{book_id=second.bookId,percent=30,exact_percent=30,fetched_at=1000}}))
    plugin.shelf_filters.reading='progress_active';plugin:showShelfView('books')
    assert(#plugin.shelf_view.books==1 and plugin.shelf_view.books[1]==second)
    cache_finished(1,1);Finish.refresh_view(plugin,second.bookId)
    assert(#plugin.shelf_view.books==0,'a confirmed finished book remained in the in-progress list')
    plugin:closeWeReadUI();plugin.settings.get_book_indexes=old_indexes;plugin.library_db=old_db;plugin.shelf_filters=old_filters
    plugin.refreshVisibleShelfProgress=old_refresh;plugin.showTransientInfo=old_notice
    shelf=plugin.settings:get('shelf');shelf.sort_order=old_sort;shelf.view_mode=old_view;shelf.paginated=old_paged
    shelf.filter_reading=old_reading;shelf.filter_download=old_download
    plugin.settings:set('shelf',shelf);plugin.settings:flush()
    plugin.shelf_group_key=nil;plugin.shelf_multi_groups={}
    return true
end
