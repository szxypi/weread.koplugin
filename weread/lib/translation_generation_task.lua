-- Worker-owned single-chapter generation, never a hidden retry or purchase.
-- The result is only available after an independent content read; a positive
-- generation status alone is not translated text.
local Native=require('weread.lib.native_read_access')
local Web=require('weread.lib.read_access')
local Source=require('weread.lib.translation_generation_source')
local Baseline=require('weread.lib.translation_generation_baseline')
local Model=require('weread.lib.translation_generation')
local Dispatch=require('weread.lib.translation_generation_dispatch')
local M={}
local function current(settings,selected,web,options)
    if not selected or not selected.scope or not web or not web.web or not web.web.cookies
        or tostring(web.web.cookies.wr_vid or '')~=selected.scope.vid or not Native.matches(settings,selected)
        or not Web.matches(settings,web) or type(options.is_current)~='function' then return false end
    local ok,value=pcall(options.is_current);return ok and value==true
end
function M.run(client,settings,selected,web,input,journal,options)
    local out={kind='unavailable',mode_attempted=false,generation_attempted=false}
    if type(options)~='table' or type(input)~='table' or type(journal)~='table' then return out end
    local function owns() return current(settings,selected,web,options) end
    local ok=pcall(function()
        assert(owns(),'translation_task/stale')
        local first=assert(Baseline.read(client,settings,selected,web,input.book_id,options))
        local source=assert(Source.inspect(client,settings,selected,input,options))
        local second=assert(Baseline.read(client,settings,selected,web,input.book_id,options))
        assert(owns() and first.digest==second.digest and first.position_present==second.position_present,'translation_task/changed')
        if source.kind=='available' then out.kind='available';return end
        assert(source.kind=='source_verified','translation_task/source')
        local plan={owner=selected.scope.vid,book_id=source.book_id,chapter_uid=tonumber(source.chapter_uid),
            book_version=source.version,translate_version=source.translate_version,grant_sha256=selected.fingerprint,
            catalog_sha256=source.catalog_sha256,source_sha256=source.source_sha256,baseline_sha256=first.digest}
        assert(Model.valid(plan),'translation_task/plan')
        local previous=journal:lookup(plan)
        if previous and not previous.same then
            if previous.phase=='prepared' then
                assert(journal:discard_stale_prepared(plan),'translation_task/storage');previous=nil
            elseif previous.phase=='mode_confirmed' then
                assert(journal:rebase_confirmed(plan),'translation_task/storage');previous={phase='mode_confirmed',same=true}
            elseif previous.phase=='response_received' then
                out.kind=previous.result=='stopped_unavailable' and 'stopped' or 'pending';return
            else out.kind='unconfirmed';return end
        end
        local record=previous and previous.same and previous or journal:prepare(plan)
        assert(record,'translation_task/storage')
        local observed_available=false
        local function recheck()
            assert(owns(),'translation_task/stale')
            local now=assert(Source.inspect(client,settings,selected,input,options))
            local baseline=assert(Baseline.read(client,settings,selected,web,input.book_id,options))
            assert(owns() and baseline.digest==plan.baseline_sha256,'translation_task/changed')
            if now.kind=='available' then observed_available=true;return nil end
            return now,baseline.digest
        end
        local dispatch_options={is_current=owns,recheck=recheck}
        if record.phase=='prepared' then
            local result=Dispatch.send_once(client,settings,selected,plan,journal,'mode',dispatch_options)
            out.mode_attempted=result.attempted
            if observed_available then out.kind='available';return end
            if result.kind~='mode_confirmed' then out.kind=result.attempted and 'unconfirmed' or 'unavailable';return end
            record=journal:state(plan)
        end
        if record and record.phase=='mode_confirmed' then
            local result=Dispatch.send_once(client,settings,selected,plan,journal,'generation',dispatch_options)
            out.generation_attempted=result.attempted
            if observed_available then out.kind='available';return end
            if result.kind~='ready' and result.kind~='pending' and result.kind~='stopped_unavailable' then
                out.kind=result.attempted and 'unconfirmed' or 'unavailable';return
            end
            record=journal:state(plan)
        end
        if not record or record.phase~='response_received' then out.kind='unconfirmed';return end
        local after=Baseline.read(client,settings,selected,web,input.book_id,options)
        if not after or after.digest~=plan.baseline_sha256 then out.kind='unconfirmed';return end
        if record.result=='stopped_unavailable' then out.kind='stopped';return end
        local content=Source.inspect(client,settings,selected,input,options)
        local final=Baseline.read(client,settings,selected,web,input.book_id,options)
        if not content or not final or final.digest~=plan.baseline_sha256 or not owns() then out.kind='unconfirmed';return end
        out.kind=content.kind=='available' and 'available' or 'pending'
    end)
    if not ok then out.kind=(out.mode_attempted or out.generation_attempted) and 'unconfirmed' or 'unavailable' end
    return out
end
return M
