-- Normal Sync on a real no-chapter marker, with no native/write authority.
return function(input,mode,counters)
    local ffi,UI=require('ffi'),require('ui/uimanager')
    local tr=require('weread.lib.plugin_util').tr;local parent=tonumber(ffi.C.getpid());local private
    local case={report={local_intent=false,no_chapter_choice=false,cancelled_locally=false,unverified=false,
        timer_stopped=false,retry_kept=false,parent_native_guard=false,offline_local_only=false,initial_offline_checkpoint=false,native_denied=0,failed_line=0}}
    local fields={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
    local function copy(p) local out={};for _i,k in ipairs(fields) do out[k]=p[k] end;return out end
    function case:is_native(o) return type(o.url)=='string' and o.url:find('https://i.weread.qq.com/',1,true)==1 end
    function case:request() counters[23]=counters[23]+1;error('unstarted/native_forbidden',0) end
    function case:reader_ready(plugin,reader,pump,index)
        if mode~='reopen' then return end
        local point=assert(plugin.settings:get_book(input.book_id).pending_upload_position.source_position)
        assert(point.raw_sha256==input.source_raw_sha256 and point.basis=='raw_txt_utf16')
        pump(function() return plugin.source_position:current()~=nil end)
        assert(plugin.source_position:current().chapter_offset==point.chapter_offset)
        local anchor=assert(index:locate(point.chapter_offset))
        assert(reader.document:isXPointerInCurrentPage(anchor.xpointer) and assert(index:capture(anchor.xpointer)).co==point.chapter_offset)
        self.offline_point=copy(point);self.report.initial_offline_checkpoint=true
    end
    function case:run(plugin,reader,pump)
        local source,sync,doc=plugin.source_position,plugin.progress_sync,reader.document
        for _i,name in ipairs({'getDocumentFileContent','getTextFromXPointers','getHTMLFromXPointers','getNextVisibleChar'}) do
            local method=doc[name];doc[name]=function(document,...)
                assert(tonumber(ffi.C.getpid())==parent,'unstarted/child_document');return method(document,...)
            end
        end
        self.report.parent_native_guard=true
        local function clean()
            while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        end
        if mode=='live' then
            local cfg=plugin.settings:get('sync');cfg.ask_on_conflict=false;cfg.upload_interval_minutes=1;cfg.upload_on_close=false
            plugin.settings:set('sync',cfg)
            clean();reader.rolling:onGotoPage(reader:getCurrentPage()==2 and 1 or 2)
            pump(function() return source:current()~=nil end)
            sync:checkpoint_local('unstarted_local_reading')
            local point=assert(source:current())
            local pending=assert(plugin.settings:get_book(input.book_id).pending_upload_position)
            assert(pending.source_position.chapter_offset==point.chapter_offset);self.report.local_intent=true
            for _i=1,2 do
                clean();assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
                local top=assert(UI:getTopmostVisibleWidget())
                assert(top.ok_text==tr('Sync current position') and type(top.ok_callback)=='function' and type(top.cancel_callback)=='function')
                assert(not sync.uploading and not plugin._native_position_review_ui)
                top.cancel_callback();UI:close(top)
                assert(not sync.verified and sync.state=='unverified' and not sync.interval.task and not sync.interval.cycle)
                local saved=assert(plugin.settings:get_book(input.book_id))
                assert(saved.pending_upload_position.source_position.chapter_offset==point.chapter_offset and not saved.last_uploaded_position
                    and saved.last_sync_error==nil and saved.last_remote_position.no_chapter.kind=='no_chapter')
            end
            self.report.no_chapter_choice,self.report.cancelled_locally,self.report.retry_kept=true,true,true
            cfg.upload_interval_minutes=0;plugin.settings:set('sync',cfg);clean()
        else
            assert(not plugin:isNetworkOnline() and self.offline_point
                and plugin.settings:get_book(input.book_id).pending_upload_position.source_position.chapter_offset==self.offline_point.chapter_offset)
            -- The common scaffold exercises page turns/source navigation after
            -- reader_ready. Return to the independently checked opening point;
            -- that earlier check cannot be repaired or hidden by this cleanup.
            local finished,applied
            assert(plugin:openSourcePosition(self.offline_point,function(p) applied,finished=p,true end))
            pump(function() return finished and source:current() end);assert(applied)
            sync:checkpoint_local('unstarted_offline_restore')
            self.report.offline_local_only=true
        end
        local saved=assert(plugin.settings:get_book(input.book_id));local checkpoint=assert(saved.pending_upload_position.source_position)
        assert(checkpoint.chapter_offset==source:current().chapter_offset and not sync.verified and not sync.uploading
            and not saved.last_uploaded_position and not sync.interval.task and not sync.interval.cycle and counters[23]==0)
        self.report.local_intent,self.report.unverified,self.report.timer_stopped=true,true,true
        private={position=copy(source:current()),checkpoint=copy(checkpoint)}
        assert(not saved.pending_upload_position.summary and not saved.last_local_position.summary)
    end
    function case:audit(filename,content)
        if filename:match('/settings/weread%.lua$') then assert(not content:find(input.source_text,1,true)) end
    end
    function case:finish(reason)
        self.report.native_denied=tonumber(counters[23])
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_unstarted_case%.lua:(%d+):')) or 0
    end
    function case:private() return private end
    return case
end
