-- Dual-channel, read-only guards for the first position of an imported book.
-- No sender, durable record, retry, or authority to modify a book lives here.
local Access=require('weread.lib.source_currentness')
local Native=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local State=require('weread.lib.cb_initial_state')
local P=require('weread.lib.native_position_protocol')
local Remote=require('weread.lib.remote_progress')
local Readback=require('weread.lib.progress_readback')
local Protocol=require('weread.lib.protocol')
local M={}

function M.capture(settings)
    local web=Access.capture(settings)
    local native=Native.capture(settings)
    if not Access.matches_cb_initial_access(settings,web,native) or not P.credentials(native.credentials) then return nil end
    return {web=web,native=native}
end
function M.current(settings,access,current)
    if type(access)~='table' or type(current)~='function'
        or not Access.matches_cb_initial_access(settings,access.web,access.native) then return false end
    local ok,value=pcall(current);return ok and value==true
end

local function read(client,settings,access,book,current)
    local function active() return M.current(settings,access,current) end
    assert(active(),'cb_initial/stale')
    local web=client:get_web_progress(book,{sensitive=true})
    assert(active(),'cb_initial/stale')
    local auth=Auth:new(client,{expected_vid=access.native.scope.vid,is_current=active})
    local ok,native=pcall(auth._request,auth,'position_progress',
        'https://i.weread.qq.com/book/getProgress?bookId='..Protocol.urlencode(book),nil,access.native.credentials)
    auth:cancel()
    if not ok then error('cb_initial/native_unavailable',0) end
    assert(active(),'cb_initial/stale')
    local node=Remote.node(native,book)
    local valid,counts=pcall(P.counts,node)
    assert(valid and counts.readingTime==0 and counts.recordReadingTime==0 and counts.ttsTime==0,'cb_initial/counts')
    return web,native
end

function M.before(client,settings,access,expected,current)
    if not State.none(expected) then return nil end
    local ok,result=pcall(function()
        local web,native=read(client,settings,access,expected.book_id,current)
        assert(State.matches(web,expected),'cb_initial/web_changed')
        local point=State.from(native,expected.book_id)
        assert(point,'cb_initial/native_changed')
        return point
    end)
    return ok and result or nil
end

function M.target(client,settings,access,target,summary,current)
    if type(target)~='table' or type(target.book_id)~='string' or target.book_id:sub(1,3)~='CB_'
        or require('weread.lib.read_access').display_book_id(target.book_id)~=target.book_id
        or not require('weread.lib.read_access').book_id(target.chapter_uid)
        or type(target.percent)~='number' or target.percent%1~=0 or not P.summary(summary) then return nil end
    local canonical=Readback.expected(target.book_id,target)
    if not canonical then return nil end
    for key,value in pairs(canonical) do if target[key]~=value then return nil end end
    local ok,result=pcall(function()
        local web,native=read(client,settings,access,target.book_id,current)
        local function matches(raw)
            local checked,remote=Readback.check(raw,target)
            local node=Remote.node(raw,target.book_id)
            assert(checked.matches and remote and remote.raw_percent==target.percent
                and node and node.summary==summary,'cb_initial/target_changed')
            return remote
        end
        local remote=matches(web);matches(native)
        return remote
    end)
    return ok and result or nil
end
return M
