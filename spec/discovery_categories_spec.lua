package.path = "./?.lua;./?/init.lua;" .. package.path
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local Data = require("weread.lib.discovery_data")
local category_response = { data = {
    { categories = {
        { CategoryId = "rising", title = "Rising", type = 0 },
        { CategoryId = "rising", title = "Duplicate" },
        { CategoryId = "100000", title = "Literature", sublist = {
            { categoryId = "100001", title = "Fiction", type = "0" },
            { CategoryId = "audio", title = "Audio", type = 1 },
        } },
        { CategoryId = "../bad", title = "Invalid" }, { CategoryId = "missing-title" }, false,
    } },
} }
local parsed = Data.categories(category_response)
expect(#parsed.ranks == 1 and parsed.ranks[1].id == "rising", "rank parsing or deduplication failed")
expect(#parsed.categories == 1 and parsed.categories[1].children[1].id == "100001"
    and #parsed.categories[1].children == 1, "category hierarchy/filtering lost")
expect(not pcall(Data.categories, {}), "missing category container treated as empty success")
expect(#Data.categories({ data = {} }).ranks == 0, "empty categories rejected")
local cyclic = { CategoryId = "200000", title = "Cycle" }
cyclic.sublist = { cyclic }
expect(#Data.categories({ data = { cyclic } }).categories[1].children == 0, "cyclic categories not bounded")
local cycle_group = {}
cycle_group[1] = { categories = cycle_group }
expect(#Data.categories({ data = cycle_group }).categories == 0, "cyclic category group not bounded")

local closed = {}
package.preload["ui/uimanager"] = function()
    return { close = function(_self, view) closed[#closed + 1] = view end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s, v) return (s:gsub("%%1", v)) end,
        display_error = tostring }
end
local Discovery = require("weread.ui.discovery")
local pending, account, fetched, shown, info, failure, request = nil, "a", 0
local plugin = setmetatable({
    library_db = { accountKey = function() return account end },
    requireLogin = function() error("public browsing requested login") end,
    runOnlineTask = function(_self, _title, fn) pending = fn return true end,
    client = {
        get_store_categories = function()
            fetched = fetched + 1
            if failure then error("offline") end
            return category_response
        end,
        get_category_books = function(_self, cid, cursor, rank)
            request = { cid = cid, cursor = cursor, rank = rank }
            if failure then error("offline") end
            return { books = { { bookInfo = { bookId = "book" }, searchIdx = cursor + 20 } }, hasMore = true }
        end,
    },
    showInfo = function(_self, text) info = text end,
    showList = function(_self, title, items)
        shown = { title = title, items = items }
        return shown
    end,
    showBookstore = function() end,
}, { __index = Discovery })
require("spec.helpers.discovery_fixture").attach(plugin)
plugin:showDiscoveryCategories()
expect(plugin.discovery_loading and fetched == 0, "category request bypassed scheduling")
pending()
expect(fetched == 1 and shown.items[1].text == "Book rankings", "category picker missing")
local menu = plugin._discovery_menu
menu.items[1].sub_item_table[1].callback()
expect(plugin._discovery_menu == nil and closed[#closed] == menu, "selecting rank retained picker")
pending()
expect(request.cid == "rising" and request.rank and request.cursor == 0, "rank selection request incorrect")
local state = plugin.discovery_state
expect(state.category_id == "rising" and state.category_title == "Rising" and state.rank,
    "rank identity not retained")
plugin:loadDiscoveryBatch("category", nil, 20, false, false, state)
pending()
state = plugin.discovery_state
expect(request.cursor == 20 and request.cid == "rising" and state.history[1] == 0,
    "rank continuation lost category or history")
failure = true
plugin:loadDiscoveryBatch("category", nil, 40, false, false, state)
pending()
expect(plugin.discovery_state == state and info, "failed category page discarded visible books")
failure = false
plugin:showDiscoveryCategories()
expect(fetched == 1, "cached category picker fetched network again")
menu = plugin._discovery_menu
local literature = menu.items[2].sub_item_table[1]
expect(literature.sub_item_table[1].text == "All in Literature", "parent category browse action missing")
literature.sub_item_table[1].callback()
pending()
expect(request.cid == "100000" and not request.rank, "All in parent used a subcategory or ranking")
plugin:showDiscoveryCategories()
menu = plugin._discovery_menu
literature = menu.items[2].sub_item_table[1]
literature.sub_item_table[2].callback()
pending()
expect(request.cid == "100001" and not request.rank and #plugin.discovery_state.history == 0,
    "subcategory reused ranking flags or history")
plugin:showDiscoveryCategories()
menu = plugin._discovery_menu
menu.close_callback()
local epoch = plugin.discovery_epoch
expect(plugin._discovery_menu == nil and epoch > 0, "closing category menu retained controller reference")
plugin:showDiscoveryCategories(true)
plugin.discovery_epoch = epoch + 1
pending()
expect(fetched == 1 and not plugin.discovery_loading, "closed screen still fetched categories")
plugin:showDiscoveryCategories(true)
account = "b"
pending()
expect(fetched == 1 and plugin._discovery_menu == nil, "categories crossed account lifecycle")
account = "a"
failure = true
local cached = plugin.discovery_categories
plugin:showDiscoveryCategories(true)
pending()
expect(plugin.discovery_categories.ranks[1].id == cached.ranks[1].id and info and not plugin.discovery_loading,
    "failed category refresh discarded cached hierarchy")
plugin.runOnlineTask = function() return false end
plugin:showDiscoveryCategories(true)
expect(not plugin.discovery_loading, "offline category load left lock active")
plugin.discovery_categories.loaded_at = os.time() - Data.CACHE_TTL - 1
plugin:showDiscoveryCategories()
expect(shown.title:find("Cached", 1, true) and fetched == 2, "offline cached categories lost or not marked stale")
plugin.discovery_categories.loaded_at=os.time()+3600
plugin:showDiscoveryCategories()
expect(shown.title:find('Cached',1,true),'clock rollback lost public hierarchy or presented it as fresh')
print("discovery_categories_spec: " .. checks .. " checks")
