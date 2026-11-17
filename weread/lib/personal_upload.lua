-- Bounded local-file upload. Credentials and file bytes stay in the worker.
local Access=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local Cos=require('weread.lib.cos_sign')
local Members=require('weread.lib.shelf_membership_write')
local Protocol=require('weread.lib.protocol')
local Read=require('weread.lib.read_access')
local M={MAX_BYTES=Cos.MAX_SINGLE_BYTES,MAX_RESULT=8*1024*1024}
local BASE='https://i.weread.qq.com'
function M.open_file(input) return require('weread.lib.personal_upload_file').open(input) end
local function fail(value) error('personal_upload/'..value,0) end
local function response_ok(value)
    return type(value)=='table' and (value.errcode==nil or value.errcode==0)
        and (value.errCode==nil or value.errCode==0)
end
local function same_file(a,b)
    return type(a)=='table' and type(b)=='table' and a.mode=='file' and b.mode=='file'
        and a.dev~=nil and a.ino~=nil and a.dev==b.dev and a.ino==b.ino
        and a.size==b.size and a.modification==b.modification and a.change==b.change
end
function M.accepts_name(name)
    if type(name)~='string' or #name>240 or name:find('[%z%c]') then return false end
    local extension=name:match('%.([A-Za-z0-9]+)$')
    local allowed={epub=true,pdf=true,mobi=true,txt=true,azw3=true}
    if not extension or not allowed[extension:lower()] then return false end
    local stem=name:sub(1,#name-#extension-1)
    return stem~='' and not stem:match('^%s*$')
end
function M.capture(path,lfs)
    if type(path)~='string' or #path>4096 or path:sub(1,1)~='/' or path:find('[%z%c]')
        or path:find('//',1,true) or Protocol.utf8_substr(path,#path+1)~=path then return nil end
    for part in path:gmatch('[^/]+') do if part=='.' or part=='..' then return nil end end
    local name=path:match('([^/]+)$');if not M.accepts_name(name) then return nil end
    local extension=name:match('%.([A-Za-z0-9]+)$')
    local stem=name:sub(1,#name-#extension-1)
    lfs=lfs or require('libs/libkoreader-lfs')
    local info=lfs.symlinkattributes(path)
    if type(info)~='table' or info.mode~='file' or info.dev==nil or info.ino==nil
        or type(info.size)~='number' or info.size<1 or info.size>M.MAX_BYTES or info.size%1~=0 then return nil end
    return {path=path,name=name,stem=stem,size=info.size,identity={mode=info.mode,dev=info.dev,ino=info.ino,
        size=info.size,modification=info.modification,change=info.change}}
end
function M.matches(input,lfs)
    if type(input)~='table' or type(input.path)~='string' then return false end
    lfs=lfs or require('libs/libkoreader-lfs')
    return same_file(input.identity,lfs.symlinkattributes(input.path))
end
local function digest(file,expected,current)
    local sha=require('ffi/sha2');local update=sha.sha256();local size=0
    while true do
        if not current() then fail('changed') end
        local part=file:read(65536)
        if not part then break end
        size=size+#part;if size>expected then fail('changed') end;update(part)
    end
    if size~=expected or not current() then fail('changed') end
    return update()
end
local function empty_object(client)
    local decoded,value=pcall(client.json_decode,client,'{}')
    local encoded,wire=pcall(client.json_encode,client,value)
    if not decoded or type(value)~='table' or next(value)~=nil or not encoded or wire~='{}' then fail('invalid_object') end
    return value
end
function M.run(client,settings,selected,input,journal,record,guard)
    local out={kind='unavailable',put_attempted=false,notify_attempted=false}
    local function current()
        return guard() and Access.matches(settings,selected) and not selected.renewal_pending
            and journal:owns(selected.scope,record) and M.matches(input)
    end
    if not current() then return out end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=current})
    local file
    local ok,reason=pcall(function()
        local before=Members.fetch(client,settings,selected);local members=assert(Members.members(before))
        local before_digest=Members.digest(members)
        file=assert(M.open_file(input));local source_hash=digest(file,input.size,current)
        if not file:seek('set',0) or not current() then fail('changed') end
        local credential=auth:_request('personal_upload_credential',BASE..'/cos/getcredential?name='..Protocol.urlencode(input.stem)..'&from=',nil,selected.credentials)
        if not response_ok(credential) then fail('credential') end
        local prepared=assert(Cos.prepare(credential,input.size,os.time()),'personal_upload/credential')
        local signed=assert(Cos.sign(prepared),'personal_upload/signature')
        if not current() then fail('changed') end
        local sha=require('ffi/sha2');local uploading=sha.sha256();local sent,overflow=0,false
        local chunks,bytes={},0
        local function source()
            if not current() then return nil,'personal_upload/changed' end
            local part=file:read(65536)
            if part then
                sent=sent+#part;if sent>input.size then return nil,'personal_upload/changed' end
                uploading(part);return part
            end
            return nil
        end
        out.put_attempted=true
        local accepted,_,status=pcall(client.request,client,{url=signed.url,method='PUT',headers=signed.headers,source=source,
            skip_cookie=true,persist_response_cookies=false,sensitive=true,diagnostic_api='personal_upload_cos',timeout={15,1800},
            sink=function(chunk) if chunk then bytes=bytes+#chunk;if bytes>65536 then overflow=true;return nil,'response_limit' end;chunks[#chunks+1]=chunk end;return 1 end})
        if not accepted or status~=200 and status~=201 or overflow or sent~=input.size or uploading()~=source_hash or not current() then fail('put_unconfirmed') end
        local url=BASE..'/cos/notify?name='..Protocol.urlencode(input.name)..'&path='..Protocol.urlencode(credential.ObjectName)..'&cancel=0'
        local notify=auth:_request('personal_upload_notify',url,empty_object(client),selected.credentials,nil,function() out.notify_attempted=true end)
        if not response_ok(notify) or type(notify.status)~='number' or notify.status~=1 or not Read.display_book_id(notify.bookId) then fail('notify_unconfirmed') end
        local id=Read.display_book_id(notify.bookId)
        if Members.contains(before,id)~=false then fail('target_exists') end
        local protected=Members.protected(before,id);if not protected then fail('preflight') end
        local expected={};for _i,value in ipairs(members) do expected[#expected+1]=value end;expected[#expected+1]=id;table.sort(expected)
        local expected_digest=Members.digest(expected)
        -- Larger imports can take longer to appear after a successful notify.
        -- Poll only the shelf in the cancellable worker; never resend the upload.
        local max_attempts=input.size>=100*1024*1024 and 16 or 9
        for attempt=1,max_attempts do
            if attempt>1 then require('socket').sleep(.5*(attempt-1)) end
            if not current() then fail('changed') end
            local after=Members.fetch(client,settings,selected);local observed=assert(Members.members(after))
            if Members.contains(after,id) and Members.digest(observed)==expected_digest and Members.protected(after,id)==protected then
                out.kind='confirmed';out.book_id=id;out.snapshot=after
                out.before_members_digest=before_digest;out.protected_digest=protected;return
            end
            -- Any unrelated visible change is not evidence of this operation.
            local without={};for _i,value in ipairs(observed) do if value~=id then without[#without+1]=value end end
            if Members.digest(without)~=before_digest or Members.protected(after,id)~=protected then fail('changed') end
        end
        fail('readback_unconfirmed')
    end)
    if file then pcall(file.close,file) end
    auth:cancel()
    if not ok then
        if out.put_attempted or out.notify_attempted then out.kind='unconfirmed'
        elseif type(reason)=='string' and (reason=='native_auth/personal_upload_credential/http_401' or reason=='native_auth/shelf/http_401') then out.kind='login'
        else out.kind='unavailable' end
    end
    return out
end
return M
