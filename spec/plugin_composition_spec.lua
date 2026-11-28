package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0

local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

local Mixin = require("weread.lib.mixin")

local inherited = { inherited_method = function() return "inherited" end }
local target = setmetatable({}, { __index = inherited })
Mixin.apply(target, {
    { first = function() return 1 end },
    { second = function() return 2 end },
})

expect(target.first() == 1, "first mixin method was not installed")
expect(target.second() == 2, "second mixin method was not installed")
expect(target.inherited_method() == "inherited",
    "mixin composition broke inherited methods")

local duplicate_ok = pcall(function()
    Mixin.apply(target, {
        { first = function() return "replacement" end },
    })
end)
expect(not duplicate_ok, "duplicate direct methods must be rejected")

local saved_catalogs = 0
local failed_chapter
package.loaded["weread.lib.content"] = {
    save_catalog_cache = function(_client, _settings, _book, chapters)
        saved_catalogs = saved_catalogs + 1
        return #chapters > 0 and chapters[1].chapterUid ~= failed_chapter
    end,
}
package.loaded.logger = {
    info = function() end,
    err = function() end,
}
package.loaded["weread.lib.plugin_util"] = {
    log_error = tostring,
}

local Migrations = require("weread.lib.migrations")
Migrations.run({has_legacy_book_records=function() return false end,
    get=function() error("modern index loaded all book records") end}, {})

local books = {
    ["123"] = { title = "Book", chapters = { { chapterUid = 1 } } },
}
local writes = 0
local settings = {
    get = function() return books end,
    has_legacy_book_records = function() return true end,
    set = function(_self, key, value)
        expect(key == "books" and value == books,
            "migration wrote an unexpected settings value")
        writes = writes + 1
    end,
    flush = function() writes = writes + 1 end,
}

Migrations.run(settings, {})
expect(saved_catalogs == 1, "legacy catalog was not persisted")
expect(books["123"].chapters == nil,
    "legacy in-record chapter list was not removed")
expect(writes == 2, "migrated settings were not saved and flushed")

books["123"].chapters = {{chapterUid=1}}
books["456"] = {chapters={{chapterUid=2}}}
failed_chapter = 2
Migrations.run(settings, {})
expect(writes == 2 and books["123"].chapters[1].chapterUid == 1 and books["456"].chapters[1].chapterUid == 2,
    "a failed catalog write discarded one of the inline catalogs")
failed_chapter = nil
Migrations.run(settings, {})
expect(writes == 4 and not books["123"].chapters and not books["456"].chapters,
    "retry did not persist successfully migrated catalogs")

print(("plugin_composition_spec: %d checks"):format(checks))
