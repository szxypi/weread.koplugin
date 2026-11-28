local Content = require("weread.lib.content")
local logger = require("weread.lib.logger")

local PluginUtil = require("weread.lib.plugin_util")
local log_error = PluginUtil.log_error

local Migrations = {}

function Migrations.run(settings, client)
    if not settings:has_legacy_book_records() then return end

    local books = settings:get("books", {})
    local migrated, failed = 0, 0
    for _book_id, book in pairs(books) do
        if type(book) == "table" and type(book.chapters) == "table" then
            local ok, saved = pcall(Content.save_catalog_cache, client, settings, book, book.chapters)
            if ok and saved then
                migrated = migrated + 1
            else
                failed = failed + 1
            end
        end
    end
    -- Splitting the settings drops inline catalogs. Preserve every original
    -- record until all catalogs have been saved so a failure can be retried.
    if failed > 0 then
        logger.err("legacy catalog migration incomplete:", "catalog_failures=", tostring(failed))
        return
    end
    for _book_id, book in pairs(books) do
        if type(book) == "table" then book.chapters = nil end
    end

    local ok, err = pcall(function()
        settings:set("books", books)
        settings:flush()
    end)
    if ok then
        logger.info("legacy per-book data migrated:", "catalogs=", tostring(migrated))
    else
        logger.err("legacy per-book data migration failed:",
            log_error(err))
    end
end

return Migrations
