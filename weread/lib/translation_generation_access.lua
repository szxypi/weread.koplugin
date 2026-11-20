-- Read-only native entitlement preflight; no credential renewal or writes.
local Access=require('weread.lib.native_read_access')
local Protocol=require('weread.lib.native_position_protocol')
local Auth=require('weread.lib.native_authorization')
local Catalog=require('weread.lib.translation_generation_catalog')
local BASE='https://i.weread.qq.com'
local M={}
local function current(settings,selected,options)
    if not selected or selected.renewal_pending or not selected.scope or not Protocol.credentials(selected.credentials)
        or selected.scope.vid~=selected.credentials.vid or not Access.matches(settings,selected) then return false end
    if type(options.is_current)~='function' then return false end
    local ok,value=pcall(options.is_current);return ok and value==true
end
function M.inspect(client,settings,selected,book_id,uid,options)
    options=options or {}
    if type(options)~='table' then return nil,'unavailable' end
    if not current(settings,selected,options) then return nil,'session_changed' end
    local valid,book_body=pcall(Catalog.catalog_body,book_id)
    if not valid then return nil,'unavailable' end
    local function owns() return current(settings,selected,options) end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=owns})
    local ok,result=pcall(function()
        local function sample()
            assert(owns(),'translation_access/stale')
            local member=Catalog.membership(auth:_request('translation_member',BASE..'/pay/memberCardSummary?pf=wechat_wx-2001-android-100-weread',nil,selected.credentials))
            assert(member.paying==true,'translation_access/member')
            local info=auth:_request('translation_book',BASE..'/book/info?bookId='..book_id,nil,selected.credentials)
            local raw=auth:_request('translation_catalog',BASE..'/book/chapterInfos',book_body,selected.credentials)
            local catalog=Catalog.catalog(raw,book_id,info)
            local chapter=Catalog.chapter(catalog,uid)
            assert(owns(),'translation_access/stale')
            return {book_id=book_id,uid=uid,version=catalog.version,catalog_sha256=catalog.digest,
                translate_version=chapter.translateVersion or 0,title=chapter.title}
        end
        local first,second=sample(),sample()
        assert(first.catalog_sha256==second.catalog_sha256 and first.version==second.version
            and first.translate_version==second.translate_version and first.title==second.title,'translation_access/changed')
        return second
    end)
    auth:cancel()
    if not ok then return nil,'unavailable' end
    return result
end
return M
