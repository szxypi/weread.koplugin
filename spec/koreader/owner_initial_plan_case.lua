-- Real native currentness preparation, with every native route forbidden.
return function(input,counters)
    local ffi,UI=require('ffi'),require('ui/uimanager');local parent=tonumber(ffi.C.getpid());local private
    local case={report={visible_point=false,local_only=false,background_worker=false,currentness_verified=false,
        integer_percent=false,parent_native_guard=false,native_denied=0,failed_line=0}}
    local source_fields={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
    local point_fields={'book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary'}
    local function fields(p,names) local out={};for _i,k in ipairs(names) do out[k]=p[k] end;return out end
    function case:is_native(o) return type(o.url)=='string' and o.url:find('https://i.weread.qq.com/',1,true)==1 end
    function case:request() counters[23]=counters[23]+1;error('initial_plan/native_forbidden',0) end
    function case:run(plugin,reader,pump,index)
        local doc,source,sync=reader.document,plugin.source_position,plugin.progress_sync
        for _i,name in ipairs({'getDocumentFileContent','getTextFromXPointers','getHTMLFromXPointers','getNextVisibleChar'}) do
            local method=doc[name];doc[name]=function(document,...)
                assert(tonumber(ffi.C.getpid())==parent,'initial_plan/child_document');return method(document,...)
            end
        end
        self.report.parent_native_guard=true
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        reader.rolling:onGotoPage(reader:getCurrentPage()==2 and 1 or 2)
        pump(function() return source:current()~=nil end)
        local point=assert(source:current());local anchor=assert(index:locate(point.chapter_offset))
        assert(doc:isXPointerInCurrentPage(anchor.xpointer) and assert(index:capture(anchor.xpointer)).co==point.chapter_offset)
        self.report.visible_point=true
        local candidate,receipt,done
        assert(source:prepare_current_native_preview(function(c,_why,r) candidate,receipt,done=c,r,true end))
        local background=false
        pump(function()
            local worker=source.preview_worker
            if worker and worker.job and worker.job.pid~=parent then background=true end
            return done
        end)
        assert(candidate and receipt and source:is_current_native_preview(receipt,candidate))
        assert(background and source.preview_worker and not source.preview_worker.job)
        self.report.background_worker,self.report.currentness_verified=true,true
        assert(candidate.raw_percent==assert(sync:capture_local()).percent and candidate.raw_percent%1==0)
        self.report.integer_percent=true
        assert(not sync.verified and not sync.uploading and candidate.upload_verified==false and point.upload_verified==false
            and not plugin.settings:get_book(input.book_id).last_uploaded_position)
        self.report.local_only=true
        private={source=fields(point,source_fields),candidate=fields(candidate,point_fields)}
        source:cancel_upload_preview();assert(not source:is_current_native_preview(receipt,candidate))
    end
    function case:audit(filename,content)
        if private and filename:match('/settings/weread%.lua$') then assert(not content:find(private.candidate.summary,1,true)) end
    end
    function case:finish(reason)
        self.report.native_denied=tonumber(counters[23])
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_initial_plan_case%.lua:(%d+):')) or 0
    end
    function case:private() return private end
    return case
end
