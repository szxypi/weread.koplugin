-- Resume only preparation that was cancelled before a durable dispatch claim.
-- Markers are transient and scoped to the original account and queue token.
local UI=require('ui/uimanager')
local M={}
local names={finish='weread.ui.finish_offline',membership='weread.ui.membership_offline'}
local function markers(host)
    host._offline_paused=host._offline_paused or {}
    return host._offline_paused
end
function M.clear(host,kind)
    if host._offline_paused then host._offline_paused[kind]=nil end
end
function M.capture(host,kind,account,job)
    local entry=job and job.entry
    if not names[kind] or not account or not job or job.claim or type(entry)~='table' or entry.phase~='queued'
        or type(entry.id)~='string' or type(entry.book_id)~='string' then return end
    markers(host)[kind]={account=account,id=entry.id,book_id=entry.book_id}
    M.wake(host)
end
function M.wake(host)
    local finish=package.loaded[names.finish]
    if finish and finish.resume_retry then finish.resume_retry(host) end
    for kind,name in pairs(names) do
        local key,module_name=kind,name
        local marker=host._offline_paused and host._offline_paused[kind]
        if marker and not marker.scheduled then
            marker.scheduled=true
            UI:nextTick(function()
                marker.scheduled=nil
                if not host._offline_paused or host._offline_paused[key]~=marker then return end
                if not host.library_db or not host.library_db.open or host.library_db:accountKey()~=marker.account then
                    M.clear(host,key);return
                end
                local module=package.loaded[module_name]
                if not module then M.clear(host,key);return end
                local entry,reason=module.get(host,marker.book_id)
                if reason or not entry or entry.id~=marker.id or entry.phase~='queued' then M.clear(host,key);return end
                if not module.can_resume_paused(host,marker.account) then return end
                M.clear(host,key)
                module.pump(host)
            end)
        end
    end
end
return M
