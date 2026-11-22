-- weread/ui/end_of_book_dialog.lua — WeRead quick navigation dialog.
--
-- Pure presentation layer: given navigation options and callbacks, it builds a
-- ButtonDialog offering bookshelf / chapter-list / next-chapter navigation. It
-- is shown both at the end of a WeRead chapter and through KOReader's gesture
-- actions. It performs no network, settings, or book-store I/O; the controller
-- computes the options and supplies the callbacks.

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local I18n = require("weread.lib.i18n")

local function _(text)
    return I18n.tr(text)
end

local M = {}

-- Show the quick menu dialog. The title already carries the WeRead brand,
-- so the buttons use plain labels (书架 / 搜索 / 目录 / 下一章).
--   opts.show_chapter_nav : boolean — show the chapter-list/next-chapter row
--                           (true only for single-chapter files, not full books)
--   opts.show_next_chapter : boolean — show the "next chapter" button
--   opts.enable_* : boolean — whether each context-dependent action is enabled
--   opts.annotations_visible : boolean — current annotation visibility state
--   callbacks             : { on_bookshelf, on_search, on_chapter_list, on_next,
--                             on_search_current, on_book_details, on_read_stats, on_sync_progress,
--                             on_toggle_annotations, on_reader_progress, on_delayed_screenshot, on_close_book }
-- Returns the dialog widget instance.
function M.show(opts, callbacks)
    opts = opts or {}
    callbacks = callbacks or {}

    local dialog

    -- Close the dialog first, then defer the action so the UI has a chance to
    -- repaint before a potentially blocking navigation (scheduleIn(0.1) keeps
    -- the event loop cooperative — see CLAUDE.md).
    local function dismiss_then(action)
        UIManager:close(dialog)
        if action then
            UIManager:scheduleIn(0.1, action)
        end
    end

    local buttons = {}

    -- Row 1: chapter list / next chapter. These stay visible in the global quick
    -- menu; the controller reports when the current document lacks WeRead
    -- chapter context.
    if opts.show_chapter_nav then
        local nav_row = {
            {
                id = 'chapter_list',
                text = _("Chapter list"),
                enabled = opts.enable_chapter_list ~= false,
                callback = function() dismiss_then(callbacks.on_chapter_list) end,
            },
        }
        if opts.show_previous_chapter then
            table.insert(nav_row, {
                id = 'previous_chapter',
                text = _("Previous chapter"),
                enabled = opts.enable_previous_chapter ~= false,
                callback = function() dismiss_then(callbacks.on_previous) end,
            })
        end
        if opts.show_next_chapter then
            table.insert(nav_row, {
                id = 'next_chapter',
                text = _("Next chapter"),
                enabled = opts.enable_next_chapter ~= false,
                callback = function() dismiss_then(callbacks.on_next) end,
            })
        end
        table.insert(buttons, nav_row)
    end

    -- Row 2: book details / reading statistics
    table.insert(buttons, {
        {
            text = _("Book details"),
            enabled = opts.enable_book_details ~= false,
            callback = function() dismiss_then(callbacks.on_book_details) end,
        },
        {
            text = _("Reading statistics"),
            callback = function() dismiss_then(callbacks.on_read_stats) end,
        },
    })

    -- Row 3: bookshelf / bookstore search
    table.insert(buttons, {
        {
            text = _("Bookshelf"),
            callback = function() dismiss_then(callbacks.on_bookshelf) end,
        },
        {
            text = _("Search bookstore"),
            callback = function() dismiss_then(callbacks.on_search) end,
        },
    })

    -- KOReader searches the open document, which may be a single chapter.
    table.insert(buttons, {
        {
            text = _("Search current file"),
            enabled = opts.enable_search_current == true,
            callback = function() dismiss_then(callbacks.on_search_current) end,
        },
        {
            text = _("Search entire book"),
            enabled = opts.enable_search_book == true,
            callback = function() dismiss_then(callbacks.on_search_book) end,
        },
    })

    table.insert(buttons, {{
        text = _("Search downloaded chapters"),
        enabled = opts.enable_search_cached == true,
        callback = function() dismiss_then(callbacks.on_search_cached) end,
    }})

    if callbacks.on_native_position_check then
        table.insert(buttons, {{id='native_position_check',text=_('Check native reading position'),
            callback=function() dismiss_then(callbacks.on_native_position_check) end}})
    end

    if opts.show_claim_location then
        table.insert(buttons, {{
            text = _("Save this page locally for this account"),
            callback = function() dismiss_then(callbacks.on_claim_location) end,
        }})
    end

    if callbacks.on_reader_progress or callbacks.on_reader_typography then
        local row={}
        if callbacks.on_reader_progress then row[#row+1]={id='reader_progress',text=_('Reading progress'),
            callback=function() dismiss_then(callbacks.on_reader_progress) end} end
        if callbacks.on_reader_typography then row[#row+1]={id='reader_typography',text=_('Reading settings'),
            callback=function() dismiss_then(callbacks.on_reader_typography) end} end
        table.insert(buttons,row)
    end

    if callbacks.on_delayed_screenshot or callbacks.on_reader_display then
        local row={}
        if callbacks.on_reader_display then row[#row+1]={id='reader_display',text=_('Page display'),
            callback=function() dismiss_then(callbacks.on_reader_display) end} end
        if callbacks.on_delayed_screenshot then row[#row+1]={id='delayed_screenshot',text=_('Delayed screenshot'),
            callback=function() dismiss_then(callbacks.on_delayed_screenshot) end} end
        table.insert(buttons,row)
    end

    -- Penultimate row: progress sync and the shared annotation visibility
    -- toggle. Keep both visible; unsupported context is represented by a
    -- disabled sync button instead of a no-op/error after tapping.
    if opts.show_sync_row~=false then table.insert(buttons, {
        {
            text = _("Sync progress now"),
            enabled = opts.enable_sync_progress ~= false,
            callback = function() dismiss_then(callbacks.on_sync_progress) end,
        },
        {
            text = opts.annotations_visible == false
                and _("Show underlines, thoughts and bookmarks")
                or _("Hide underlines, thoughts and bookmarks"),
            callback = function() dismiss_then(callbacks.on_toggle_annotations) end,
        },
    }) end

    -- Final row: cancel / close book
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        },
        {
            text = _("Close book"),
            callback = function() dismiss_then(callbacks.on_close_book) end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("WeRead · Quick menu"),
        buttons = buttons,
    }

    UIManager:show(dialog)
    return dialog
end

return M
