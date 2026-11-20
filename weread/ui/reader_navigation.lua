-- End-of-book navigation dialog integration.
local EndOfBookDialog = require("weread.ui.end_of_book_dialog")
local PluginUtil = require("weread.lib.plugin_util")
local WeRead = require("weread.lib.protocol")

local _ = PluginUtil.tr

local M = {}

-- Dispatcher entry point used by KOReader gesture/profile actions. The quick
-- menu is a global WeRead entry point; actions that need a current WeRead book
-- explain why they are unavailable when invoked from another document.
function M:onShowWeReadQuickMenu()
    return self:showEndOfBookDialog(self:detectWeReadBook())
end

-- General gesture action works from the file manager and reader.
function M:onShowWeReadDelayedScreenshot()
    require('weread.ui.delayed_screenshot').show(self)
    return true
end

-- Dispatcher entry point for a gesture that opens the WeRead bookshelf from
-- any document currently open in KOReader.
function M:onShowWeReadBookshelf()
    self:showBookshelf()
    return true
end

function M:onShowWeReadLocalBookshelf()
    self:showWereadCollection()
    return true
end

function M:onShowWeReadReadingStatistics()
    self:showReadStats()
    return true
end

function M:onShowWeReadSearch()
    self:showSearch()
    return true
end

function M:showEndOfBookDialog(book_id)
    local reader_ui = self.ui
    local document = reader_ui and reader_ui.document
    local search = reader_ui and reader_ui.search
    local file_path = document and document.file
    if not file_path then return false end
    local reader_session = self._reader_session_gen or 0
    local search_scope = self.settings.get_auth_scope and self.settings:get_auth_scope()
    local search_epoch = self.settings:get('auth_epoch', 0)

    local books = self.settings:get("books", {})
    local book = book_id and (books[tostring(book_id)] or books[book_id]) or nil
    local is_regular_weread_book = book ~= nil and not WeRead.is_mp_book(book_id)
    local chapters = is_regular_weread_book and self:ensureChaptersLoaded(book) or nil

    local current_idx, current_chapter, is_full_book
    if chapters then
        local chapter_info = { self:getChapterInfoFromFile(book, file_path) }
        current_idx, current_chapter, is_full_book = chapter_info[1], chapter_info[2], chapter_info[3]
    end
    -- The chapter-nav row is shown only for single downloaded chapters (a mapped
    -- current chapter that is not part of a full-book EPUB); "next chapter"
    -- additionally requires a successor.
    local next_chapter = current_idx and not is_full_book
        and chapters[current_idx + 1] or nil
    local previous_chapter = current_idx and not is_full_book and chapters[current_idx - 1] or nil
    local function chapter_id(ch) return ch and tostring(ch.chapterUid or ch.chapterId or '') or nil end
    local current_id,previous_id,next_id=chapter_id(current_chapter),chapter_id(previous_chapter),chapter_id(next_chapter)

    local function show_context_required()
        self:showTransientInfo(
            _("This action requires an open WeRead book."), 1)
    end

    -- Keep the reader quick menu in sync with the global display preference.
    -- Document-level matching may be incomplete while chapters are being
    -- prepared, but the user's show/hide choice is still authoritative here.
    local cache = self.settings:get("cache", {})
    local annotations_visible = cache.show_annotations ~= false
    local location=self._native_account_location and require('weread.lib.native_account_location')
    EndOfBookDialog.show({
        show_chapter_nav = true,
        show_next_chapter = true,
        enable_chapter_list = chapters ~= nil,
        enable_next_chapter = next_chapter ~= nil,
        enable_book_details = book ~= nil,
        enable_sync_progress = is_regular_weread_book,
        enable_search_current = type(search) == "table" and type(search.onShowFulltextSearchInput) == "function",
        enable_search_book = is_regular_weread_book and require('weread.lib.read_access').display_book_id(tostring(book_id)) ~= nil,
        enable_search_cached = is_regular_weread_book and require('weread.lib.read_access').display_book_id(tostring(book_id)) ~= nil,
        show_claim_location = location and location.can_claim(self) or false,
        annotations_visible = annotations_visible,
    }, {
        on_bookshelf = function()
            self:showBookshelf()
        end,
        on_search = function()
            self:showSearch()
        end,
        on_search_current = function()
            if self.ui == reader_ui and reader_ui.document == document and document.file == file_path and reader_ui.search == search
                and type(search) == "table" and type(search.onShowFulltextSearchInput) == "function" then
                search:onShowFulltextSearchInput()
            end
        end,
        on_search_book = function()
            local current_scope = self.settings.get_auth_scope and self.settings:get_auth_scope()
            local same_scope = search_scope and self.settings:auth_scope_matches(search_scope)
                or not search_scope and not current_scope
            if self.ui == reader_ui and reader_ui.document == document and document.file == file_path
                and (self._reader_session_gen or 0)==reader_session and same_scope then
                local uid
                if tostring(book_id):sub(1,3)=='CB_' then
                    uid=current_chapter and tostring(current_chapter.chapterUid or current_chapter.chapterId or '') or nil
                    if not uid and not is_full_book and book.cached_full_book~=file_path
                        and type(book.cached_chapters)=='table' then
                        local mapped,count=nil,0
                        for chapter,path in pairs(book.cached_chapters) do
                            if path==file_path then mapped,count=tostring(chapter),count+1 end
                        end
                        if count==1 then uid=mapped end
                    end
                    if self.source_position and type(self.source_position.current)=='function' then
                        local ok,point=pcall(self.source_position.current,self.source_position)
                        if ok and type(point)=='table' and point.book_id==tostring(book_id) and point.chapter_uid then
                            uid=tostring(point.chapter_uid)
                        end
                    end
                end
                require('weread.ui.book_search').open(self,tostring(book_id),chapters,uid)
            end
        end,
        on_search_cached = function()
            local current_scope = self.settings.get_auth_scope and self.settings:get_auth_scope()
            local same_scope = search_scope and self.settings:auth_scope_matches(search_scope)
                or not search_scope and not current_scope
            if self.ui == reader_ui and reader_ui.document == document and document.file == file_path
                and (self._reader_session_gen or 0)==reader_session and same_scope
                and self.settings:get('auth_epoch',0)==search_epoch then
                require('weread.ui.cached_book_search').open(self,tostring(book_id),chapters)
            end
        end,
        on_chapter_list = function()
            if chapters then
                self:showChapterList(book)
            else
                show_context_required()
            end
        end,
        on_next = function()
            if next_chapter then
                self:openChapter(book, next_chapter)
            elseif is_regular_weread_book then
                self:showTransientInfo(_("You have reached the last chapter."), 1)
            else
                show_context_required()
            end
        end,
        on_book_details = function()
            if book then
                self:showCurrentBookDetails()
            else
                show_context_required()
            end
        end,
        on_reader_progress = function()
            local function still_current()
                local current_scope = self.settings.get_auth_scope and self.settings:get_auth_scope()
                local same_scope = search_scope and self.settings:auth_scope_matches(search_scope)
                    or not search_scope and not current_scope
                if self.ui ~= reader_ui or reader_ui.document ~= document or document.file ~= file_path
                    or (self._reader_session_gen or 0) ~= reader_session or not same_scope
                    or self.settings:get('auth_epoch',0) ~= search_epoch then return false end
                if current_idx then
                    if book.chapters~=chapters or chapters[current_idx]~=current_chapter
                        or chapters[current_idx-1]~=previous_chapter or chapters[current_idx+1]~=next_chapter
                        or chapter_id(current_chapter)~=current_id or chapter_id(previous_chapter)~=previous_id
                        or chapter_id(next_chapter)~=next_id then return false end
                    local index,chapter,combined=self:getChapterInfoFromFile(book,file_path)
                    if index~=current_idx or chapter~=current_chapter or combined~=is_full_book then return false end
                end
                return true
            end
            local ok,valid=pcall(still_current)
            if ok and valid then
                local expected={book=book,book_id=tostring(book_id),file=file_path,index=current_idx,
                    current=current_id,previous=previous_id,next=next_id}
                local function resolve_chapter(direction)
                    return require('weread.lib.reader_progress_chapter').resolve(self,expected,direction)
                end
                require('weread.ui.reader_progress').show(self,{previous=previous_chapter,next=next_chapter,
                    single_chapter=current_idx~=nil and not is_full_book,
                    book=book,chapters=chapters,chapter_index=current_idx,chapter_uid=current_id,
                    native_chapters=not current_idx or is_full_book,is_current=still_current,
                    resolve_chapter=resolve_chapter})
            end
        end,
        on_reader_typography = function()
            local current_scope=self.settings.get_auth_scope and self.settings:get_auth_scope()
            local same_scope=search_scope and self.settings:auth_scope_matches(search_scope)
                or not search_scope and not current_scope
            if self.ui==reader_ui and reader_ui.document==document and document.file==file_path
                and (self._reader_session_gen or 0)==reader_session and same_scope
                and self.settings:get('auth_epoch',0)==search_epoch then
                require('weread.ui.reader_typography').show(self)
            end
        end,
        on_delayed_screenshot = function()
            self:onShowWeReadDelayedScreenshot()
        end,
        on_read_stats = function()
            self:showReadStats()
        end,
        on_sync_progress = function()
            if is_regular_weread_book then
                self:onWeReadSyncProgress()
            else
                show_context_required()
            end
        end,
        on_claim_location = function()
            local saved=location and location.claim(self)
            self:showTransientInfo(saved and _('Local reading position saved for this account.')
                or _('Could not save this reading position.'),3)
        end,
        on_toggle_annotations = function()
            self:toggleAnnotationVisibility()
        end,
        on_close_book = function()
            -- Mirror KOReader's ReaderStatus:openFileBrowser(): closing the
            -- reader alone exits the app when there is no file-manager stack, so
            -- reopen the file browser right after (positioned on the book file).
            local ui = self.ui
            if not ui then return end
            local file = ui.document and ui.document.file
            ui:onClose()
            if file and ui.showFileManager then
                ui:showFileManager(file)
            end
        end,
    })
    return true
end

return M
