-- Real bookReader source preparation only. No uploader or native credentials.
return function(input,counters)
    assert(input.native_source_excerpt==true and input.source_format=='web_txt')
    local case={records=require('json').decode('[]'),report={normal_capture=false,page_turn_capture=false,
        retained_target=false,parent_native_guard=false,opaque_receipts=false,movement_invalidates_receipt=false,
        source_gate_preserved=false,legacy_units_preserved=false,position_restored=false,
        text_not_in_source_state=false,text_not_in_settings=false,page_child_cancelled=false,close_child_cancelled=false,
        fresh_policy_verified=false,currentness_checks=0,
        background_workers=0,excerpts=0,failed_line=0,denied_shape=0,denied_checks=0,denied_api=0}}
    function case:run(plugin,reader,pump,index,origin)
        local service,doc=plugin.source_position,reader.document
        local Source=require('weread.lib.position_source')
        local ffi=require('ffi');local parent=tonumber(ffi.C.getpid())
        local native_read=doc.getDocumentFileContent
        doc.getDocumentFileContent=function(document,...)
            assert(tonumber(ffi.C.getpid())==parent,'excerpt child touched inherited native document')
            return native_read(document,...)
        end
        local function ready(retained)
            pump(function()
                local p,state=service:current()
                assert(state~='unavailable' and state~='unsupported' and state~='paused','excerpt source unavailable')
                return p and (p.retained_source_target==true)==retained
            end)
            return assert(service:current())
        end
        local previous_current
        local function capture(stage,retained)
            local point=ready(retained)
            assert(point.book_id==input.book_id and point.chapter_uid==input.chapter_uid
                and point.raw_sha256==input.source_raw_sha256 and point.basis=='raw_txt_utf16' and point.upload_verified==false)
            if previous_current then
                assert(not previous_current(),'old view receipt remained current')
                self.report.movement_invalidates_receipt=true
            end
            if stage=='page' and not plugin:isNetworkConnected() then
                local done,why
                service:prepare_current_native_preview(function(value,reason,receipt)
                    assert(not value and not receipt);done,why=true,reason
                end)
                assert(done and why=='offline','offline currentness attempted network')
                self.report.fresh_policy_verified=true
            end
            local legacy=assert(plugin.progress_sync:capture_local())
            local packet,receipt,done
            service:prepare_native_excerpt(function(value,_why,token) packet,receipt,done=value,token,true end)
            local worker=assert(service.preview_worker and service.preview_worker.job)
            assert(worker.pid~=parent);self.report.background_workers=self.report.background_workers+1
            pump(function() return done end)
            assert(packet and receipt and next(receipt)==nil and service:is_current_native_excerpt(receipt,packet))
            assert(not service:is_current_native_excerpt({},packet))
            assert(packet.position.chapter_offset==point.chapter_offset and packet.position.raw_sha256==point.raw_sha256
                and packet.position.file_id==point.file_id and packet.position.book_version==point.book_version
                and packet.position.upload_verified==false and packet.excerpt.upload_verified==false)
            local target=assert(index:locate(point.chapter_offset))
            assert(doc:isXPointerInCurrentPage(target.xpointer) and assert(index:capture(target.xpointer)).co==point.chapter_offset)
            local after=assert(plugin.progress_sync:capture_local())
            assert(after.chapter_offset==legacy.chapter_offset and after.chapter_idx==legacy.chapter_idx
                and after.chapter_uid==legacy.chapter_uid and after.percent==legacy.percent)
            local rejected,complete
            plugin.source_upload:prepare(after,function(plan,why) rejected=not plan and why=='source_format_unsupported';complete=true end)
            assert(complete and rejected,'native excerpt enabled the XHTML sender')
            local current=assert(service:current())
            assert(not current.excerpt and not current.summary and not after.source_position.excerpt and not after.source_position.summary)
            previous_current=function() return service:is_current_native_excerpt(receipt,packet) end
            if stage=='page' and plugin:isNetworkConnected() then
                local prepared,token,finished
                service:prepare_current_native_preview(function(value,_why,checked) prepared,token,finished=value,checked,true end)
                pump(function() return finished end)
                local live=assert(service.get_upload_context())
                local expected=assert(require('weread.lib.native_source_candidate').project(packet,live.chapters,live.percent))
                assert(require('weread.lib.source_upload_candidate').same(expected,prepared)
                    and token and next(token)==nil and service:is_current_native_preview(token,prepared))
                assert(service:native_preview_deadline(token,prepared))
                previous_current=function() return service:is_current_native_preview(token,prepared) end
                self.report.fresh_policy_verified=true;self.report.currentness_checks=1
            end
            self.records[#self.records+1]={stage=stage,packet=packet,legacy={chapter_uid=tostring(legacy.chapter_uid),
                chapter_idx=legacy.chapter_idx,chapter_offset=legacy.chapter_offset,percent=legacy.percent}}
            self.report.excerpts=#self.records
        end
        local function jump(point)
            local done,value
            assert(plugin:openSourcePosition(point,function(result) value,done=result,true end))
            pump(function() return done end);assert(value);ready(true)
        end
        local ok,reason=pcall(function()
            assert(doc:getPageCount()>=4)
            reader.rolling:onGotoPage(4);ready(false)
            reader.rolling:onGotoPage(3);capture('page',false);self.report.normal_capture=true
            local Task=require('weread.lib.source_position_worker')
            local prepare=Task.prepare_native_excerpt
            Task.prepare_native_excerpt=function(value) require('socket').sleep(2);return prepare(value) end
            local stale=false
            service:prepare_native_excerpt(function() stale=true end)
            local child=assert(service.preview_worker.job).pid
            reader.rolling:onGotoPage(4);Task.prepare_native_excerpt=prepare
            ready(false);pump(function() return require('ffi/util').isSubProcessDone(child) end)
            assert(not stale and not service.preview_job,'old page excerpt delivered')
            self.report.page_child_cancelled=true
            capture('turned',false);self.report.page_turn_capture=true
            local target=assert(index:locate(input.source_sample_offset))
            local xp=target.xpointer;for _i=1,3 do xp=assert(doc:getNextVisibleChar(xp)) end
            local actual=assert(index:capture(xp))
            local record=assert(Source.document_metadata(doc,input.book_id,input.chapter_uid)).record
            local retained={basis='raw_txt_utf16',upload_verified=false,chapter_offset=actual.co}
            for _i,key in ipairs({'book_id','chapter_uid','file_id','book_version','raw_sha256','render_path'}) do retained[key]=record[key] end
            jump(retained);capture('retained',true);self.report.retained_target=true
            self.report.parent_native_guard,self.report.opaque_receipts=true,true
            self.report.source_gate_preserved,self.report.legacy_units_preserved,self.report.text_not_in_source_state=true,true,true
        end)
        local restored=pcall(jump,origin);self.report.position_restored=restored
        doc.getDocumentFileContent=native_read
        assert(ok,reason);assert(restored,'excerpt restore failed')
        -- Leave a confirmed live preparation to the normal ReaderUI close.
        -- The base probe owns close/reopen and waits for every child to reap.
        local Task=require('weread.lib.source_position_worker');local prepare=Task.prepare_native_excerpt
        Task.prepare_native_excerpt=function(value) require('socket').sleep(2);return prepare(value) end
        local late=false
        service:prepare_native_excerpt(function() late=true end)
        local child=assert(service.preview_worker.job).pid
        Task.prepare_native_excerpt=prepare
        local stop=service.stop
        service.stop=function(active)
            case.close_observed=active.preview_worker and active.preview_worker.job and active.preview_worker.job.pid==child
            return stop(active)
        end
        self.close_check=function()
            return self.close_observed==true and not late and not service.preview_job
                and require('ffi/util').isSubProcessDone(child)
        end
    end
    function case:audit(filename,content)
        if filename:match('/settings/weread%.lua$') then
            for _i,row in ipairs(self.records) do
                if #row.packet.excerpt.text>=24 then assert(not content:find(row.packet.excerpt.text,1,true),'excerpt persisted in settings') end
            end
            self.report.text_not_in_settings=true
        end
    end
    function case:finish(reason)
        self.report.denied_shape,self.report.denied_checks,self.report.denied_api=tonumber(counters[20]),tonumber(counters[21]),tonumber(counters[22])
        self.report.close_child_cancelled=self.close_check and self.close_check() or false
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_native_excerpt_case%.lua:(%d+):')) or 0
    end
    function case:private() return {records=self.records} end
    return case
end
