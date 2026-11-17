-- Focused test for context-sensitive actions in the WeRead quick menu.

package.path = "./?.lua;" .. package.path

local shown
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, dialog) shown = dialog end,
        close = function() end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end

local Dialog = require("weread.ui.end_of_book_dialog")

local bookstore_searches, file_searches, book_searches, cached_searches = 0, 0, 0, 0
local callbacks = {
    on_bookshelf = function() end,
    on_search = function() bookstore_searches = bookstore_searches + 1 end,
    on_search_current = function() file_searches = file_searches + 1 end,
    on_search_book = function() book_searches = book_searches + 1 end,
    on_search_cached = function() cached_searches = cached_searches + 1 end,
    on_book_details = function() end,
    on_read_stats = function() end,
    on_sync_progress = function() end,
    on_toggle_annotations = function() end,
    on_close_book = function() end,
}
Dialog.show({
    show_chapter_nav = true,
    show_next_chapter = true,
    enable_chapter_list = true,
    enable_next_chapter = false,
    enable_book_details = false,
    enable_sync_progress = true,
    enable_search_current = true,
    enable_search_book = true,
    enable_search_cached = true,
    annotations_visible = true,
}, callbacks)

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

expect(shown and shown.title == "WeRead · Quick menu",
    "quick menu keeps the requested title")
local sync_row = shown and shown.buttons[#shown.buttons - 1]
expect(sync_row and #sync_row == 2,
    "sync and annotation visibility share the penultimate row")
expect(sync_row and sync_row[1].text == "Sync progress now",
    "the row starts with immediate progress sync")
expect(sync_row and sync_row[2].text == "Hide underlines, thoughts and bookmarks",
    "the row shows the current annotation toggle action")
expect(shown.buttons[1][1].text == "Chapter list"
        and shown.buttons[1][2].text == "Next chapter",
    "chapter actions stay visible in the global quick menu")
expect(shown.buttons[1][1].enabled == true
        and shown.buttons[1][2].enabled == false,
    "chapter actions reflect their individual availability")
expect(shown.buttons[2][1].enabled == false
        and sync_row[1].enabled == true,
    "book details and progress sync reflect their availability")
expect(shown.buttons[3][2].text == "Search bookstore"
        and shown.buttons[4][1].text == "Search current file" and shown.buttons[4][1].enabled == true
        and shown.buttons[4][2].text == "Search entire book" and shown.buttons[4][2].enabled == true,
    "bookstore and current document search have distinct actions")
expect(shown.buttons[5][1].text=='Search downloaded chapters' and shown.buttons[5][1].enabled,
    'downloaded chapter search has its own native action')
shown.buttons[3][2].callback();shown.buttons[4][1].callback();shown.buttons[4][2].callback();shown.buttons[5][1].callback()
expect(bookstore_searches==1 and file_searches==1 and book_searches==1 and cached_searches==1,
    "each search button delegates to the corresponding action")

Dialog.show({
    enable_book_details = false,
    enable_sync_progress = false,
    annotations_visible = false,
}, callbacks)
sync_row = shown and shown.buttons[#shown.buttons - 1]
expect(#shown.buttons == 6,
    "shared action row remains visible without WeRead book context")
expect(shown.buttons[3][1].enabled == false and shown.buttons[3][2].enabled == false,
    "current file search is disabled without a native search module")
expect(sync_row and sync_row[1].enabled == false,
    "progress sync is disabled without WeRead book context")
expect(sync_row and sync_row[2].text == "Show underlines, thoughts and bookmarks",
    "hidden annotations expose the show action")
local claimed=0
Dialog.show({show_claim_location=true},{on_claim_location=function() claimed=claimed+1 end})
local claim
for _,row in ipairs(shown.buttons) do for _,button in ipairs(row) do
    if button.text=='Save this page locally for this account' then claim=button end
end end
expect(claim~=nil,'legacy account location action was not shown')
if claim then claim.callback() end
expect(claimed==1,'legacy account location action did not delegate')

print(string.format(
    "end_of_book_dialog_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
