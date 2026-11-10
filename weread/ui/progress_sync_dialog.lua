local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local I18n = require("weread.lib.i18n")

local ProgressSyncDialog = {}

local function _(text)
    return I18n.tr(text)
end

local function percent(position)
    return string.format("%.0f", tonumber(position and position.percent) or 0)
end

function ProgressSyncDialog.show_choice(context)
    local message
    if context.source_conflict then
        message = T(_(
            "WeRead's two progress sources disagree for \"%1\".\n\n"
            .. "KOReader: %2%\nSelected cloud position: %3%\n\n"
            .. "Choose which position to keep."
        ), context.book_title, percent(context.local_position),
            percent(context.remote_position))
    else
        message = T(_(
            "Reading progress differs for \"%1\".\n\n"
            .. "KOReader: %2%\nWeRead: %3%\n\n"
            .. "Choose which position to keep."
        ), context.book_title, percent(context.local_position),
            percent(context.remote_position))
    end

    UIManager:show(ConfirmBox:new{
        title = _("Reading progress sync"),
        text = message,
        ok_text = _("Use WeRead progress"),
        cancel_text = _("Keep KOReader progress"),
        ok_callback = context.use_remote,
        cancel_callback = context.keep_local,
    })
end

function ProgressSyncDialog.notify(code, data)
    data = data or {}
    local text
    if code == "upload_success" then
        text = T(_("Progress uploaded to WeRead: %1%"),
            percent(data.position))
    elseif code == "upload_unconfirmed" then
        text = _("The cloud position could not be confirmed.\nYour local position is kept. This upload will not be sent again automatically. Please sync again later to compare positions.")
    elseif code == "upload_failed" then
        if data.error=='source_authentication_unavailable' then
            text=_("Could not restore login for checking this position. Your local position is kept. Please check login and sync again.")
        elseif data.error=='source_format_unsupported' then
            text=_("Cloud position sync is not available for this file format yet. Your local position is kept.")
        elseif data.error=='source_no_visible_text' then
            text=_("This page has no text position to check.")
        elseif data.error=='source_data_unavailable' then
            text=_("This file has no original position data. Download the chapter again to check its position.")
        elseif type(data.error)=='string' and data.error:match('^source_') then
            text=_("The original reading position is not ready to sync. Your local position is kept. Please try again shortly.")
        else text = T(_("Progress upload failed:\n%1"), tostring(data.error or "")) end
    elseif code == "already_synced" then
        text = _("KOReader and WeRead are already at the same position.")
    elseif code == "remote_applied" then
        text = T(_("Jumped to WeRead progress: %1%"),
            percent(data.position))
    elseif code == "local_kept" then
        text = _("Kept the current KOReader position.")
    elseif code == "pull_failed" then
        if data.error == "progress_book_mismatch" then
            text = _("WeRead returned a position that does not match this book.\nYour current position is kept. Please try syncing again later.")
        elseif data.error == "progress_invalid" or data.error == "progress_ambiguous"
            or data.error == "progress_rejected" or data.error == "progress_not_found" then
            text = _("WeRead's reading position could not be verified.\nYour current position is kept. Please try syncing again later.")
        else
            text = T(_("Could not fetch WeRead progress:\n%1"), tostring(data.error or ""))
        end
    elseif code == "jump_failed" then
        text = T(_("Could not jump to WeRead progress:\n%1"),
            tostring(data.error or ""))
    elseif code == "local_unavailable" then
        text = T(_("Could not determine the current reading position:\n%1"),
            tostring(data.error or ""))
    elseif code == "authentication_required" then
        text = _("Please scan the QR code to log in first.")
    elseif code == "offline" then
        text = _("No network connection. Please connect Wi-Fi and try again.")
    else
        return
    end
    UIManager:show(InfoMessage:new{ text = text })
end

return ProgressSyncDialog
