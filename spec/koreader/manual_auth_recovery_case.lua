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
        host:showChapterList(book)
        local view=assert(host._chapter_list_view)
        view._toolbar_buttons[2].callback()
        local menu=assert(UI:getTopmostVisibleWidget())
        local selected=0
        for _,item in ipairs(menu.item_table or {}) do
            local label=item.text_func and item.text_func() or ''
            if label:find('第5章',1,true) or label:find('第6章',1,true) then item.callback();selected=selected+1 end
        end
        assert(selected==2,'selected chapter rows missing')
        request('/__control',{match=shard,times=1,skip=1,status=401,web_renewal_mode='rotate'})
        menu.item_table[1].callback()
        pump(function()
            local reader=Reader.instance
            local saved_book=reader and reader.weread and reader.weread.settings:get_book(book.book_id or book.bookId)
            return reader and reader.document and reader.document.file~=first and saved_book and saved_book.cached_chapters
                and saved_book.cached_chapters['5'] and saved_book.cached_chapters['6']
        end)
        assert(count('/web/login/renewal')==initial_renewal+1,'selected download did not renew once')
        assert(count(shard)-before==4,'selected download did not restart only the intended chapters')
        host.showInfo=old_info
        record()
    end
    return M
end
