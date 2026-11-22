-- Optional E-Ink resources for one chapter. Web bytes remain the only position
-- authority; mismatched or unsupported packages leave the ordinary path intact.
local Access = require('weread.lib.native_read_access')
local Source = require('weread.lib.native_chapter_source')
local Remote = require('weread.lib.native_chapter_remote')
local Position = require('weread.lib.position_source')
local Crypto = require('weread.lib.crypto')
local M = {}

local function fatal(reason)
    if reason == 'native_resources/source_changed' then reason = 'source_changed' end
    if reason == 'rate_limited' then error('download_read/rate_limited', 0) end
    if reason == 'auth_expired' or reason == 'service_rejected'
        or reason == 'session_changed' or reason == 'source_changed' then
        error('native_candidate/' .. reason, 0)
    end
end

function M.fetch(client, settings, book, chapter, web, position, workspace, expected_fingerprint, check_live)
    local book_id = tostring(book.book_id or book.bookId or '')
    local uid = tostring(chapter.chapterUid or chapter.chapterId or '')
    local verified = Position.resolve(position, book_id, uid)
    if not verified or verified.format ~= 'web_xhtml' or verified.data ~= web
        or type(workspace) ~= 'table' or type(workspace.asset_dir) ~= 'string' then return nil end
    local selected = Access.capture(settings)
    if expected_fingerprint and (not selected or selected.fingerprint ~= expected_fingerprint) then
        fatal('session_changed')
    end
    if not selected or selected.renewal_pending then return nil end
    local function current()
        if check_live then check_live() end
        return Access.matches(settings, selected)
    end
    local source, why = Source.fetch(client, settings, selected, book_id, uid, { is_current = current })
    if not source then
        if check_live then check_live() end
        fatal(why); return nil
    end
    if not current() then fatal('session_changed') end
    if source.body ~= web then return nil end
    local prepared
    prepared, why = Remote.complete(client, source, { is_current = current })
    if not prepared then
        if check_live then check_live() end
        fatal(why); return nil
    end
    if not current() then fatal('session_changed') end
    local ok_lfs, lfs = pcall(require, 'libs/libkoreader-lfs')
    if not ok_lfs then ok_lfs, lfs = pcall(require, 'lfs') end
    if not ok_lfs or lfs.attributes(workspace.asset_dir, 'mode') ~= 'directory' then
        error('native_candidate/storage', 0)
    end
    local assets = {}
    for _, asset in ipairs(prepared.assets) do
        local extension = ({ ['image/png']='png', ['image/jpeg']='jpg',
            ['image/gif']='gif', ['image/webp']='webp' })[asset.media_type]
        local digest = type(asset.data) == 'string' and Crypto.sha256_hex(asset.data)
        local name = extension and digest and 'eink-' .. digest .. '.' .. extension
        if not name or asset.href ~= 'images/' .. name then error('native_candidate/invalid_asset', 0) end
        local path = workspace.asset_dir .. '/' .. name
        -- The workspace is private to this download; never replace existing files.
        if lfs.symlinkattributes(path) then error('native_candidate/storage', 0) end
        local part = path .. '.part'
        if lfs.symlinkattributes(part) then error('native_candidate/storage', 0) end
        local file = io.open(part, 'wb')
        if not file then error('native_candidate/storage', 0) end
        local written, closed = file:write(asset.data), file:close()
        if not written or not closed or not current() or not os.rename(part, path) then
            os.remove(part)
            if not current() then fatal('session_changed') end
            error('native_candidate/storage', 0)
        end
        assets[#assets + 1] = { href=asset.href, media_type=asset.media_type, path=path, size=#asset.data }
    end
    if not current() then fatal('session_changed') end
    return { xhtml=prepared.xhtml, css=prepared.css, assets=assets }
end
return M
