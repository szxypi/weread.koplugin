-- No progress dispatcher or uploader is used. The base transport stays read-only.
return function(input)
    assert(input.source_upload_preview==true and input.source_format=='web_xhtml')
    local Source=require('weread.lib.position_source')
    local Dom=require('weread.lib.source_dom')
    local fields={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
    local case={records=require('json').decode('[]'),report={normal_capture=false,page_turn_capture=false,retained_target=false,
        native_dom_summary=false,legacy_units_preserved=false,reader_position_restored=false,
        source_gate_preserved=false,summary_not_in_source_state=false,summary_not_in_settings=false,
        currentness_policy_verified=false,currentness_receipt_invalidated=false,currentness_checks=0,
        background_workers_observed=false,candidates=0,background_workers=0,legacy_equal_source=0,failed_line=0,preparation_failure=0,
        capture_failure_state=0,capture_failure_reason=0,unexpected_retained=0,capture_origin_kind=0,next_text_visible=0}}
    function case:run(plugin,reader,pump,index,origin)
        local document,service=reader.document,plugin.source_position
        local native_read=document.getDocumentFileContent
        local ffi=require('ffi');local parent=tonumber(ffi.C.getpid())
        document.getDocumentFileContent=function(native_document,...)
            assert(tonumber(ffi.C.getpid())==parent,'candidate_child_native_document')
            return native_read(native_document,...)
        end
        local function ready(retained)
            local ok=pcall(pump,function()
                local value,state=service:current()
                if state=='unavailable' or state=='unsupported' or state=='paused' then error('candidate_capture_unavailable',0) end
                return value and (value.retained_source_target==true)==retained
            end)
            if not ok then
                local point,state,reason=service:current()
                self.report.capture_failure_state=({idle=1,waiting=2,preparing=3,ready=4,unavailable=5,paused=6,deferred=7,stale=8,unsupported=9})[state] or 10
                self.report.capture_failure_reason=({context_unmatched=1,source_changed=2,source_unavailable=3,context_unavailable=4,
                    resources_unavailable=5,worker_unavailable=6,position_unavailable=7,no_visible_text=8})[reason] or (reason and 9 or 0)
                self.report.unexpected_retained=point and point.retained_source_target and 1 or 0
                local location=require('weread.lib.source_context').location(document,reader.view.view_mode)
                if location then
                    local xp=location.xpointer
                    self.report.capture_origin_kind=xp:find('/text()',1,true) and 1 or xp:find('/img',1,true) and 2 or 3
                    local next_point=document:getNextVisibleChar(xp)
                    local Position=require('weread.lib.reader_position')
                    local frame=Position.snapshot(document,reader.view.view_mode,plugin.progress_sync.get_viewport_height())
                    self.report.next_text_visible=type(next_point)=='string' and next_point:find('/text()',1,true)
                        and Position.contains_anchor(document,frame,next_point) and 1 or 0
                end
                error('candidate_capture_unavailable',0)
            end
            return assert(service:current())
        end
        local function capture(label,retained)
            local point=ready(retained)
            assert(point.book_id==input.book_id and point.chapter_uid==input.chapter_uid
                and point.raw_sha256==input.source_raw_sha256 and point.basis=='filtered_xhtml_utf16' and point.upload_verified==false)
            if not retained then
                local location=assert(require('weread.lib.source_context').location(document,reader.view.view_mode))
                local xp=location.xpointer
                if not xp:find('/text()',1,true) then
                    xp=assert(document:getNextVisibleChar(xp))
                    assert(xp:find('/text()',1,true) and document:isXPointerInCurrentPage(xp))
                end
                assert(assert(index:capture(xp)).co==point.chapter_offset)
            end
            local legacy=assert(plugin.progress_sync:capture_local())
            local candidate,reason,done
            service:prepare_upload_preview(function(value,why) candidate,reason,done=value,why,true end)
            local worker=service.preview_worker and service.preview_worker.job
            assert(worker and worker.pid~=parent,'candidate_worker_not_observed')
            self.report.background_workers=self.report.background_workers+1
            pump(function() return done end)
            if not candidate then
                self.report.preparation_failure=({source_unsupported=1,resources_unavailable=2,context_unavailable=3,
                    candidate_unavailable=4,worker_unavailable=5})[reason] or 6
            end
            assert(candidate,'candidate_unavailable')
            assert(candidate.chapter_offset==point.chapter_offset and candidate.percent==legacy.percent
                and candidate.book_id==input.book_id and candidate.chapter_uid==input.chapter_uid and candidate.upload_verified==false)
            if label=='page' then
                local fresh,why,receipt,completed
                service:prepare_current_upload_preview(function(value,problem,checked) fresh,why,receipt,completed=value,problem,checked,true end)
                pump(function() return completed end)
                if plugin:isNetworkConnected() then
                    assert(require('weread.lib.source_upload_candidate').same(fresh,candidate)
                        and service:is_current_upload_preview(receipt,fresh),'candidate_current_source_unverified')
                    self.report.currentness_checks=1
                    self.checked_receipt,self.checked_candidate=receipt,fresh
                else assert(not fresh and not receipt and why=='offline','candidate_offline_currentness_dispatched') end
                self.report.currentness_policy_verified=true
            elseif label=='turned' then
                assert(not service:is_current_upload_preview(self.checked_receipt,self.checked_candidate),'candidate_movement_retained_receipt')
                self.checked_receipt,self.checked_candidate=nil,nil
                self.report.currentness_receipt_invalidated=true
            end
            local target=assert(index:locate(point.chapter_offset))
            assert(document:isXPointerInCurrentPage(target.xpointer))
            assert(assert(index:capture(target.xpointer)).co==point.chapter_offset)
            local ending=target.xpointer
            for _i=1,80 do
                local next_point=document:getNextVisibleChar(ending)
                if not next_point or Dom.fragment(next_point)~=Dom.fragment(target.xpointer) then break end
                ending=next_point
            end
            local text=assert(Dom.normalize(document:getTextFromXPointers(target.xpointer,ending)))
            document:clearSelection()
            local chars={}
            for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
                if #chars==20 then break end
                chars[#chars+1]=char
            end
            assert(candidate.summary==table.concat(chars),'candidate_dom_summary')
            local after=assert(plugin.progress_sync:capture_local())
            assert(after.chapter_offset==legacy.chapter_offset and after.chapter_idx==legacy.chapter_idx
                and after.chapter_uid==legacy.chapter_uid and after.percent==legacy.percent,'candidate_legacy_changed')
            local current=assert(service:current())
            assert(not current.summary and not current.candidate and not after.source_position.summary and not after.source_position.candidate)
            if candidate.chapter_offset==legacy.chapter_offset then self.report.legacy_equal_source=self.report.legacy_equal_source+1 end
            local source={};for _i,key in ipairs(fields) do source[key]=point[key] end
            self.records[#self.records+1]={stage=label,source=source,candidate=candidate,legacy={
                chapter_uid=tostring(legacy.chapter_uid),chapter_idx=legacy.chapter_idx,chapter_offset=legacy.chapter_offset,percent=legacy.percent}}
            self.report.candidates=#self.records
            return point
        end
        local function jump(point)
            local value
            assert(plugin:openSourcePosition(point,function(result) value=result or false end))
            pump(function() return value~=nil end);assert(value)
            local held=ready(true)
            assert(held.chapter_offset==point.chapter_offset and held.chapter_uid==point.chapter_uid)
            local target=assert(index:locate(point.chapter_offset))
            assert(document:isXPointerInCurrentPage(target.xpointer) and assert(index:capture(target.xpointer)).co==point.chapter_offset)
        end
        local ok,reason=pcall(function()
            assert(document:getPageCount()>=4)
            reader.rolling:onGotoPage(4);ready(false)
            reader.rolling:onGotoPage(3);capture('page',false);self.report.normal_capture=true
            reader.rolling:onGotoPage(4);capture('turned',false);self.report.page_turn_capture=true
            local anchor=assert(index:locate(input.source_sample_offset))
            local xp=anchor.xpointer
            for _i=1,3 do xp=assert(document:getNextVisibleChar(xp)) end
            local actual=assert(index:capture(xp))
            local snapshot=assert(Source.document_metadata(document,input.book_id,input.chapter_uid))
            local target={basis='filtered_xhtml_utf16',upload_verified=false,chapter_offset=actual.co}
            for _i,key in ipairs({'book_id','chapter_uid','file_id','book_version','raw_sha256','render_path'}) do target[key]=snapshot.record[key] end
            jump(target);capture('retained',true);self.report.retained_target=true
            self.report.native_dom_summary,self.report.legacy_units_preserved=true,true
            self.report.summary_not_in_source_state,self.report.source_gate_preserved=true,true
            self.report.background_workers_observed=self.report.background_workers==3
        end)
        local restored=pcall(jump,origin)
        self.report.reader_position_restored=restored
        document.getDocumentFileContent=native_read
        assert(ok,reason);assert(restored,'candidate_restore_failed')
    end
    function case:audit(filename,content)
        if filename:match('/settings/weread%.lua$') then
            for _i,row in ipairs(self.records) do assert(not content:find(row.candidate.summary,1,true),'candidate_summary_in_settings') end
            self.report.summary_not_in_settings=true
        end
    end
    function case:finish(reason)
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_source_candidate_case%.lua:(%d+):')) or 0
    end
    function case:private() return {records=self.records} end
    return case
end
