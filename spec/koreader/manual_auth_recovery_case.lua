-- Exercise manual chapter downloads through native menus and mock HTTP.
return function(host,kind,pump,tick)
    local UI=require('ui/uimanager')
    local Reader=require('apps/reader/readerui')
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local M={}
    local function request(path,data)
        local chunks,raw={},data and Json.encode(data)
        local _,code=HTTP.request{url=host.settings.mock_endpoint..path,proxy=host.settings.mock_endpoint,
            method=raw and 'POST' or 'GET',source=raw and LTN.source.string(raw),
            headers=raw and {['Content-Type']='application/json',['Content-Length']=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function count(path)
        local total=0
        for _,row in ipairs(request('/__state').totals) do if row.path==path then total=total+row.count end end
        return total
    end
    local shard='/web/book/chapter/'..(os.getenv('WEREAD_TEST_CONTENT_FORMAT')=='txt' and 't_0' or 'e_0')
    local initial_renewal=count('/web/login/renewal')
    local before=count(shard)
    local notice,old_info=nil,host.showInfo
    host.showInfo=function(self,text,...) notice=text;return old_info(self,text,...) end
    local function record()
        local file=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/manual-auth-recovery.json','wb'))
        file:write(Json.encode{result='PASS',stage=kind,renewals=1,complete_chapters_only=true});file:close()
    end
    function M.arm_single()
        request('/__control',{match=kind=='single-reader' and '/web/reader/' or shard,
            times=kind=='single-repeat' and -1 or 1,status=401,web_renewal_mode='rotate'})
    end
    function M.recover_single(view)
        pump(function() return notice~=nil end)
        assert(notice==require('weread.lib.i18n').tr('WeRead login expired. Please sign in again and retry the download.'))
        assert(count('/web/login/renewal')==initial_renewal+1,'second 401 retried renewal')
        request('/__control',{match='',times=0})
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=view do UI:close(UI:getTopmostVisibleWidget()) end
        tick();view._chapter_rows[4].callback()
    end
    function M.check_single()
        host.showInfo=old_info
        assert(count('/web/login/renewal')==initial_renewal+1,'manual chapter renewal count is wrong')
        local expected=kind=='single-reader' and 1 or kind=='single-repeat' and 3 or 2
        assert(count(shard)-before==expected,'manual chapter requests were repeated or skipped')
        record()
    end
    function M.selected(book,first)
        local Util=require('weread.lib.plugin_util')
        local with_images=os.getenv('WEREAD_TEST_CONTENT_FORMAT')~='txt'
        local source_version=with_images and 7 or 0
        book.bookVersion=source_version
        request('/__control',{catalog_source_version=source_version})
        local previous_page_size=G_reader_settings:readSetting('items_per_page')
        G_reader_settings:saveSetting('items_per_page',4)
        host:showChapterList(book)
        local view=assert(host._chapter_list_view)
        view._toolbar_buttons[2].callback()
        local menu=assert(UI:getTopmostVisibleWidget())
        local function filter(title)
            UI:forceRePaint()
            assert(menu.title_bar.left_button).callback()
            local dialog=assert(menu._shelf_popup)
            dialog:setInputText(title)
            dialog.buttons[1][2].callback()
        end
        local unfiltered_page=menu.page_num
        assert(unfiltered_page>1)
        menu:onGotoPage(unfiltered_page)
        filter('第')
        local bulk,chapter_rows={},0
        for index,item in ipairs(menu.item_table) do
            if item.text==Util.tr('Matching chapters…') then bulk[#bulk+1]=index end
            if item.chapter_index then chapter_rows=chapter_rows+1 end
        end
        assert(#bulk>1 and chapter_rows>=6,'filtered chapter selection has no actions across pages')
        menu:onGotoPage(menu:getPageNumber(bulk[2]))
        for _,selection in ipairs({{button=1,count=chapter_rows},{button=2,count=0}}) do
            menu:onMenuSelect(menu.item_table[bulk[2]])
            local actions=assert(menu._shelf_popup)
            actions.buttons[selection.button][1].callback()
            pump(function() return menu._shelf_popup==nil end)
            assert(menu.item_table[1].text==Util.T(Util.tr('[Download] Selected chapters (%1)'),tostring(selection.count)),
                'bulk action did not update chapters on every page')
        end
        if previous_page_size then G_reader_settings:saveSetting('items_per_page',previous_page_size)
        else G_reader_settings:delSetting('items_per_page') end
        menu:onMenuSelect(menu.item_table[bulk[2]])
        assert(menu._shelf_popup).buttons[3][1].callback()
        pump(function() return menu._shelf_popup==nil end)
        assert(menu.item_table[1].text==Util.tr('Choose the first chapter to download')
            and menu.item_group[1].text==Util.tr('Choose the first chapter to download')
            and menu.item_group[2].text==Util.tr('Cancel range'), 'visible range actions were not updated')
        for _,title in ipairs({'第6章','第5章'}) do
            filter(title)
            assert(menu.subtitle:find(title,1,true) and #menu.item_table==3,'download filter showed the wrong chapters')
            local item=menu.item_table[3]
            assert(item.text:find(title,1,true),'filtered download row did not retain the chapter title')
            menu:onMenuSelect(item)
            local expected=title=='第6章' and 'Range start' or 'Selected'
            assert(item.mandatory==Util.tr(expected) and menu.item_group[3].mandatory==Util.tr(expected))
        end
        assert(menu.item_table[1].text==Util.T(Util.tr('[Download] Selected chapters (%1)'),'2'),
            'selection across two queries was lost')
        filter('')
        assert(menu.page==unfiltered_page and menu.item_table[1].text==Util.T(Util.tr('[Download] Selected chapters (%1)'),'2'),
            'clearing the filter lost the original page or the selected chapters')
        local cache=host.settings:get('cache')
        local old_images=cache.download_book_images
        if with_images then
            cache.download_book_images=true;host.settings:set('cache',cache);host.settings:flush()
        end
        request('/__control',{match=shard,times=1,skip=1,status=401,web_renewal_mode='rotate'})
        menu:onMenuSelect(menu.item_table[menu:getFirstVisibleItemIndex()])
        pump(function()
            local reader=Reader.instance
            local saved_book=reader and reader.weread and reader.weread.settings:get_book(book.book_id or book.bookId)
            return reader and reader.document and reader.document.file~=first and saved_book and saved_book.cached_chapters
                and saved_book.cached_chapters['5'] and saved_book.cached_chapters['6']
        end)
        assert(count('/web/login/renewal')==initial_renewal+1,'selected download did not renew once')
        assert(count(shard)-before==(source_version>0 and 3 or 4),
            'selected download did not preserve staged text only for a verified matching version')
        if with_images then
            local settings=assert(Reader.instance.weread).settings
            local saved=settings:get_book(book.book_id or book.bookId)
            local Archive=require('weread.lib.source_archive')
            local chapter_entry='OEBPS/text/chapter.xhtml'
            for _,uid in ipairs({'5','6'}) do
                local path=saved.cached_chapters[uid]
                local chapter=assert(Archive.read(path,{[chapter_entry]=256*1024}))[chapter_entry]
                local image='OEBPS/'..assert(chapter:match('src="%.%./(images/[^"]+)"'))
                local bytes=assert(Archive.read(path,{[image]=256*1024}))[image]
                assert(bytes and bytes:sub(1,4)=='\137PNG','selected EPUB dropped its staged illustration')
            end
            cache=settings:get('cache');cache.download_book_images=old_images
            settings:set('cache',cache);settings:flush()
        end
        request('/__control',{catalog_source_version=0})
        host.showInfo=old_info
        record()
    end
    return M
end
