-- Ordinary Sync -> Use WeRead progress. No native transport or write authority.
return function(input,mode,counters)
    local json,ffi,UI=require('json'),require('ffi'),require('ui/uimanager')
    local tr=require('weread.lib.plugin_util').tr;local trial=input.raw_cloud_preview
    local parent=tonumber(ffi.C.getpid());local private
    local case={report={local_intent_created=false,cloud_choice=false,background_worker=false,raw_target=false,
        sync_verified=false,pending_cleared=false,checkpoint_saved=false,truthful_notice=false,parent_native_guard=false,
        offline_checkpoint=false,offline_local_only=false,native_denied=0,failed_line=0}}
    local fields={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
    local function copy(value)
        local result={};for _i,key in ipairs(fields) do result[key]=assert(value)[key] end;return result
    end
    function case:is_native(options) return type(options.url)=='string' and options.url:find('https://i.weread.qq.com/',1,true)==1 end
    function case:request()
        counters[23]=counters[23]+1;error('cloud_source/native_forbidden',0)
    end
    function case:reader_ready(plugin,reader,pump,index)
        if mode~='reopen' then return end
        local saved=assert(plugin.settings:get_book(input.book_id));local point=assert(saved.last_local_position.source_position)
        assert(point.basis=='raw_txt_utf16' and point.chapter_offset==trial.baseline.chapter_offset
            and point.raw_sha256==input.source_raw_sha256 and not saved.pending_upload_position)
        local anchor=assert(index:locate(point.chapter_offset))
        assert(reader.document:isXPointerInCurrentPage(anchor.xpointer) and assert(index:capture(anchor.xpointer)).co==point.chapter_offset)
        pump(function() return plugin.source_position:current() and plugin.progress_sync.current_book_id end)
        assert(plugin.source_position:current().chapter_offset==point.chapter_offset,'offline raw anchor changed')
        self.reopen_checkpoint=copy(point)
        self.report.offline_checkpoint=true
    end
    function case:run(plugin,reader,pump,index,origin)
        local source,sync,doc=plugin.source_position,plugin.progress_sync,reader.document
        for _i,name in ipairs({'getDocumentFileContent','getTextFromXPointers','getHTMLFromXPointers','getNextVisibleChar'}) do
            local method=doc[name];doc[name]=function(document,...)
                assert(tonumber(ffi.C.getpid())==parent,'cloud_source/child_document');return method(document,...)
            end
        end
        self.report.parent_native_guard=true
        local function jump(co)
            local point=json.decode(json.encode(origin));point.chapter_offset=co
            local finished,applied
            assert(plugin:openSourcePosition(point,function(value) finished,applied=true,value end))
            pump(function() return finished and source:current() end);assert(applied and source:current().chapter_offset==co)
        end
        if mode=='live' then
            jump(trial.target.chapter_offset);sync:checkpoint_local('cloud_source_preview')
            assert(plugin.settings:get_book(input.book_id).pending_upload_position.source_position.chapter_offset==trial.target.chapter_offset)
            self.report.local_intent_created=true
            local cfg=plugin.settings:get('sync');cfg.ask_on_conflict=true;plugin.settings:set('sync',cfg)
            assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
            local dialog=assert(UI:getTopmostVisibleWidget())
            assert(dialog.ok_text==tr('Use WeRead progress') and dialog.cancel_text==tr('Keep KOReader progress'))
            local notice,transient=nil,plugin.showTransientInfo
            plugin.showTransientInfo=function(host,text,...) notice=text;return transient(host,text,...) end
            dialog.ok_callback();UI:close(dialog);self.report.cloud_choice=true
            assert(plugin.cloud_source_worker and plugin.cloud_source_worker.job);self.report.background_worker=true
            pump(function() return not plugin.cloud_source_request and not plugin.source_navigation.job end)
            plugin.showTransientInfo=transient
            assert(sync.verified and not sync.uploading and not sync.dirty);self.report.sync_verified=true
            assert(notice==tr('Cloud reading position opened and sync comparison saved.'));self.report.truthful_notice=true
            local saved=assert(plugin.settings:get_book(input.book_id))
            assert(not saved.pending_upload_position and not saved.last_uploaded_position);self.report.pending_cleared=true
            assert(saved.last_local_position.source_position.chapter_offset==trial.baseline.chapter_offset
                and saved.last_remote_position.chapter_offset==trial.baseline.chapter_offset);self.report.checkpoint_saved=true
            private={position=copy(assert(source:current())),checkpoint=copy(saved.last_local_position.source_position)}
        else
            assert(self.report.offline_checkpoint and not plugin:isNetworkOnline())
            jump(trial.baseline.chapter_offset);assert(not sync.verified and not sync.uploading)
            self.report.offline_local_only=true
            private={position=copy(assert(source:current())),checkpoint=self.reopen_checkpoint}
        end
        local point=assert(source:current());local anchor=assert(sync.source_anchor)
        assert(point.basis=='raw_txt_utf16' and point.upload_verified==false and point.chapter_offset==trial.baseline.chapter_offset
            and point.raw_sha256==input.source_raw_sha256 and anchor.document==doc and doc:isXPointerInCurrentPage(anchor.xpointer)
            and assert(index:capture(anchor.xpointer)).co==trial.baseline.chapter_offset)
        assert(counters[23]==0);self.report.raw_target=true
    end
    function case:audit(filename,content)
        if filename:match('/settings/weread%.lua$') then
            assert(not content:find(trial.baseline.summary,1,true) and not content:find(trial.target.summary,1,true))
        end
    end
    function case:finish(reason)
        self.report.native_denied=tonumber(counters[23])
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_cloud_source_case%.lua:(%d+):')) or 0
    end
    function case:private() return private end
    return case
end
