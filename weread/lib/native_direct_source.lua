-- Prepare E-Ink chapter content without a Web reader session. This is not a
-- Web position proof; callers must keep sync and annotation coordinates apart.
local Access=require('weread.lib.native_read_access')
local Source=require('weread.lib.native_chapter_source')
local Remote=require('weread.lib.native_chapter_remote')
local Protocol=require('weread.lib.native_position_protocol')
local Crypto=require('weread.lib.crypto')
local M={}

local function hash(value)
    return type(value)=='string' and #value==64 and value:match('^[0-9a-f]+$')~=nil
end

function M.fetch(client,settings,book_id,chapter_uid,expected,options)
    if type(book_id)~='string' or Protocol.id(book_id)~=book_id or type(chapter_uid)~='string'
        or Protocol.id(chapter_uid)~=chapter_uid or type(expected)~='table'
        or expected.book_id~=book_id or expected.chapter_uid~=chapter_uid
        or not Protocol.integer(expected.book_version,0,2147483647)
        or not hash(expected.reading_catalog_sha256) or not hash(expected.access_fingerprint)
        or type(options)~='table' or type(options.is_current)~='function' then return nil,'invalid' end
    local current,selected=Access.guard(settings,options.is_current)
    if not current or selected.fingerprint~=expected.access_fingerprint then
        return nil,'session_changed'
    end
    if not current() then return nil,'session_changed' end
    local source,why=Source.fetch(client,settings,selected,book_id,chapter_uid,
        {is_current=current,expected_catalog=expected})
    if not source then return nil,why or 'unavailable' end
    if not current() then return nil,'session_changed' end
    if source.book_id~=book_id or source.chapter_uid~=chapter_uid or source.book_version~=expected.book_version
        or source.reading_catalog_sha256~=expected.reading_catalog_sha256 then return nil,'catalog_changed' end
    if source.source_channel~='eink' or source.coordinate_source_authoritative~=false
        or type(source.body)~='string' or not hash(source.catalog_sha256) then return nil,'invalid_source' end
    if source.is_text==true then return nil,'unsupported_format' end
    local prepared
    prepared,why=Remote.complete(client,source,{is_current=current,allow_missing_images=options.allow_missing_images==true})
    if not prepared then return nil,why or 'unavailable' end
    if not current() then return nil,'session_changed' end
    if type(prepared.xhtml)~='string' or type(prepared.css)~='string' or type(prepared.assets)~='table'
        or prepared.coordinate_source_authoritative~=false then return nil,'invalid_source' end
    local missing=prepared.missing_images or 0
    if not Protocol.integer(missing,0,64) then return nil,'invalid_source' end
    local xhtml=prepared.xhtml
    if missing>0 then
        local warning=require('weread.lib.i18n').tr('Some images could not be loaded; placeholders are shown.')
        warning=warning:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;')
        local banner='<p>'..warning..'</p>'
        local start=xhtml:find('<body[%s>]')
        local ending=start and xhtml:find('>',start,true)
        if ending then xhtml=xhtml:sub(1,ending)..banner..xhtml:sub(ending+1)
        else xhtml=banner..xhtml end
    end
    local css=require('weread.lib.content').sanitize_book_css(prepared.css)
    if not current() then return nil,'session_changed' end
    return {book_id=book_id,chapter_uid=chapter_uid,book_version=source.book_version,
        catalog_sha256=source.catalog_sha256,reading_catalog_sha256=source.reading_catalog_sha256,
        source_sha256=Crypto.sha256_hex(source.body),source_raw=source.body,xhtml=xhtml,css=css,assets=prepared.assets,missing_images=missing,
        source_channel='eink',coordinate_source_authoritative=false}
end
return M
