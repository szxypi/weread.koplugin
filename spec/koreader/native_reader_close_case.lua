-- Real ReaderUI close and detached native operation, loopback synthetic only.
return function(reader,plugin,pump,clean,counters,pids,report)
    local Face=require('weread.lib.native_close_source');local Native=require('weread.lib.native_source_upload')
    local face_factory,native_factory=Face.new,Native.new
    local face,controller;local closed=false
    Face.new=function(self,options) face=face_factory(self,options);return face end
    Native.new=function(self,options)
        local value=native_factory(self,options)
        if options.source==face then controller=value end
        return value
    end
    local ffi,json=require('ffi'),require('json');local parent=tonumber(ffi.C.getpid())
    local function waiting(predicate)
        pump(function()
            for _i,worker in pairs({face and face.worker,controller and controller.worker,controller and controller.service.worker}) do
                if worker.job then assert(worker.job.pid~=parent);pids[worker.job.pid]=true end
            end
            return predicate()
        end)
    end
    local ok,why=pcall(function()
        local kind=report.kind
        assert(kind=='plain' or kind=='noack' or kind=='cancel' or kind=='reopen' or kind=='account')
        local id=assert(plugin:detectWeReadBook());local sync=plugin.progress_sync
        local config=plugin.settings:get('sync');config.upload_on_close=true;config.upload_interval_minutes=0
        plugin.settings:set('sync',config)
        clean(reader);reader.rolling:onGotoPage(reader:getCurrentPage()==2 and 1 or 2)
        pump(function() return plugin.source_position:current()~=nil end)
        local point=assert(plugin.source_position:current());local legacy=assert(sync:capture_local())
        assert(sync.verified and sync.dirty and point.basis=='raw_txt_utf16')
        if kind=='noack' then
            local _,code=plugin.client:request{url='https://weread.qq.com/mock/native-control',method='POST',body=json.encode{mode='noack'},
                headers={['Content-Type']='application/json'},skip_cookie=true,persist_response_cookies=false,sensitive=true};assert(code==200)
        end
        local request=plugin.client.request
        function plugin.client:request(options)
            if options.url=='https://i.weread.qq.com/book/read' then
                assert(closed,'native close POST preceded native document close');counters[2]=counters[2]+1
                local body=json.decode(options.body)
                assert(body.chapterOffset==point.chapter_offset and body.currentProgress==legacy.percent and body.readingTime==0)
            end
            return request(self,options)
        end
        local document=reader.document
        for _i,name in ipairs({'getDocumentFileContent','getTextFromXPointers','getHTMLFromXPointers','getNextVisibleChar',
            'getPrevVisibleChar','getXPointer','getCurrentPage','getPageCount'}) do
            local method=document[name]
            document[name]=function(doc,...)
                if closed then counters[4]=counters[4]+1;error('closed native document touched: '..name,0) end
                assert(tonumber(ffi.C.getpid())==parent,'inherited closed native document')
                return method(doc,...)
            end
        end
        reader:onClose(false);closed=true;report.document_closed=true
        waiting(function() return face and face.worker and face.worker.job end)
        report.archive_worker=true
        local pid=face.worker.job.pid;pids[pid]=true
        if kind=='cancel' then plugin.source_close:cancel()
        elseif kind=='reopen' then
            local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
            FM:showFiles(assert(os.getenv('KO_HOME')));local host=FM.instance.weread
            host.isNetworkOnline=function() return false end;host.isNetworkConnected=host.isNetworkOnline
            host:showBookshelf();local book
            for _i,row in ipairs(host.shelf_view.books) do if tostring(row.bookId or row.book_id)==id then book=row;break end end
            assert(book);host.shelf_view.on_select(book)
            pump(function() return Reader.instance or host._book_detail_view and not host.book_metadata_context end)
            if not Reader.instance then
                local selected=false
                for _i,buttons in ipairs({host._book_detail_view._action_buttons or {},host._book_detail_view._footer_actions or {}}) do
                    for _j,button in ipairs(buttons) do if button.text==require('weread.lib.plugin_util').tr('▤ Read') then button.callback();selected=true;break end end
                    if selected then break end
                end
                assert(selected)
            end
            pump(function() return Reader.instance and Reader.instance.weread.progress_sync.current_book_id end)
            local current=Reader.instance;clean(current);current:onClose(false)
        elseif kind=='account' then
            plugin.settings:update_auth({account={user_vid='900099',name='Synthetic'},cookies={wr_vid='900099',wr_skey='synthetic-new-cookie'},api_key=''},
                {replace_cookies=true})
        end
        waiting(function() return not sync.uploading end)
        waiting(function() return require('ffi/util').isSubProcessDone(pid) end)
        local saved=plugin.settings:get_book(id)
        if kind=='plain' then
            assert(counters[2]==1 and not saved.pending_upload_position and saved.last_uploaded_position.wire_basis=='raw_txt_utf16'
                and saved.last_uploaded_position.chapter_offset==point.chapter_offset and not saved.last_uploaded_position.summary)
            assert(saved.last_local_position.chapter_offset==legacy.chapter_offset and not controller.service:pending())
            report.confirmed=true
        elseif kind=='noack' then
            assert(counters[2]==1 and saved.pending_upload_position and saved.pending_upload_reason=='upload_readback_unconfirmed'
                and controller.service:pending().phase=='pending');report.unknown_retained=true
        else
            assert(counters[2]==0,'cancelled closed preparation sent a late write');report.cancelled=true
            if kind~='account' then assert(saved.pending_upload_position,'cancelled close lost local intent') end
        end
        for child_pid in pairs(pids) do waiting(function() return require('ffi/util').isSubProcessDone(child_pid) end) end
        assert(counters[4]==0);report.workers_reaped,report.no_closed_document_calls=true,true
    end)
    Face.new,Native.new=face_factory,native_factory
    report.close_posts=tonumber(counters[2])
    if not ok then report.failed_line=tonumber(type(why)=='string' and why:match('native_reader_close_case%.lua:(%d+):')) or 0 end
    assert(ok,why)
end
