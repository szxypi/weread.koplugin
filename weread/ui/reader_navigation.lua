-- End-of-book navigation dialog integration.
local EndOfBookDialog = require("weread.ui.end_of_book_dialog")
local PluginUtil = require("weread.lib.plugin_util")
local ReadAccess = require("weread.lib.read_access")
local WeRead = require("weread.lib.protocol")

local _ = PluginUtil.tr

local M = {}
local function cancel_pending_note(host)
    local navigation=package.loaded['weread.ui.my_mark_navigation']
    if navigation and navigation.cancel_incoming then navigation.cancel_incoming(host) end
end

-- Dispatcher entry point used by KOReader gesture/profile actions. The quick
-- menu is a global WeRead entry point; actions that need a current WeRead book
-- explain why they are unavailable when invoked from another document.
function M:onShowWeReadQuickMenu()
    cancel_pending_note(self)
    local file=self.ui and self.ui.document and self.ui.document.file
    if require('weread.lib.native_direct_path').contains(self.settings,file) then
        return require('weread.ui.native_direct_navigation').start(self)
    end
    return self:showEndOfBookDialog(self:detectWeReadBook())
end

-- General gesture action works from the file manager and reader.
function M:onShowWeReadDelayedScreenshot()
    cancel_pending_note(self)
    require('weread.ui.delayed_screenshot').show(self)
    return true
end

-- Dispatcher entry point for a gesture that opens the WeRead bookshelf from
-- any document currently open in KOReader.
function M:onShowWeReadBookshelf()
    cancel_pending_note(self)
    self:showBookshelf()
    return true
end

function M:onShowWeReadLocalBookshelf()
    cancel_pending_note(self)
    self:showWereadCollection()
    return true
end

function M:onShowWeReadReadingStatistics()
    cancel_pending_note(self)
    self:showReadStats()
    return true
end

function M:onShowWeReadSearch()
    cancel_pending_note(self)
    self:showSearch()
    return true
end

function M:openReaderChapter(book, chapter)
    if not self.isNetworkLinkAvailable or self:isNetworkLinkAvailable() then
        return self:openChapter(book, chapter)
    end
    return self:openChapter(book, chapter, nil, {
        cached_only = true,
        on_cache_miss = function()
            return self:showEndOfBookDialog(book.book_id or book.bookId, nil, {
                subtitle = _('Chapter unavailable offline'),
                unavailable_chapter = tostring(chapter.chapterUid or chapter.chapterId),
            })
        end,
    })
end

function M:showEndOfBookDialog(book_id, at_end, downloads)
    local reader_ui = self.ui
    local document = reader_ui and reader_ui.document
    local search = reader_ui and reader_ui.search
    local file_path = document and document.file
    if not file_path then return false end
    local reader_session = self._reader_session_gen or 0
    -- A suspend and resume can leave the viewport unchanged.
    local progress_sync = self.progress_sync
    local sync_generation = progress_sync and progress_sync.generation
    local navigation_generation = progress_sync and progress_sync.navigation_generation
    local search_scope = self.settings.get_auth_scope and self.settings:get_auth_scope()
    local search_epoch = self.settings:get('auth_epoch', 0)

    local book = book_id and ReadAccess.load_cached_book(self.settings, book_id) or nil
    local is_regular_weread_book = book ~= nil and not WeRead.is_mp_book(book_id)
    local has_saved_chapters = is_regular_weread_book and (
        type(book.cached_chapters) == 'table' and next(book.cached_chapters) ~= nil
        or type(book.cached_full_book) == 'string' or type(book.cached_file) == 'string')

    local identity={}
    for _,key in ipairs({'bookVersion','book_version','version','fileId','file_id','cache_dir'}) do
        identity[key]=book and book[key] or nil
    end
    local function reader_current()
        local scope=self.settings.get_auth_scope and self.settings:get_auth_scope()
        local same=search_scope and self.settings:auth_scope_matches(search_scope) or not search_scope and not scope
        return self.ui==reader_ui and reader_ui.document==document and document.file==file_path
            and (self._reader_session_gen or 0)==reader_session and same
            and self.settings:get('auth_epoch',0)==search_epoch
    end
    local function valid_reader()
        local ok,current=pcall(reader_current)
        return ok and current==true
    end
    local function matching_book(fresh)
        if type(fresh)~='table' or tostring(fresh.book_id or fresh.bookId or '')~=tostring(book_id) then return false end
        for key,value in pairs(identity) do if tostring(fresh[key])~=tostring(value) then return false end end
        for _,key in ipairs({'bookVersion','book_version','version','fileId','file_id','cache_dir'}) do
            if identity[key]==nil and fresh[key]~=nil then return false end
        end
        return true
    end
    local function load_current_book()
        if not valid_reader() then return end
        local ok, fresh = pcall(ReadAccess.load_cached_book, self.settings, book_id)
        if not valid_reader() then return end
        if ok and matching_book(fresh) then return fresh end
        self:showTransientInfo(_('Chapter information changed. Open the quick menu again.'), 3)
    end
    local function show_downloaded_chapters()
        self:showSavedChapters(book_id, nil, {
            is_current = valid_reader, load_book = load_current_book,
            subtitle = downloads and downloads.subtitle,
            unavailable_chapter = downloads and downloads.unavailable_chapter,
        })
    end
    if downloads and (has_saved_chapters or downloads.subtitle and is_regular_weread_book) then
        show_downloaded_chapters()
        return true
    end
    local chapters = is_regular_weread_book and self:ensureChaptersLoaded(book, true) or nil
    local downloaded_only = not chapters and has_saved_chapters
    local current_idx, current_chapter, is_full_book, partial, proof
    if chapters then
        book.chapters=chapters
        current_idx,current_chapter,is_full_book,partial,proof=self:getChapterInfoFromFile(book,file_path)
    end
    -- The progress panel uses KOReader's own chapter navigation for combined files.
    local next_chapter = current_idx and not is_full_book and chapters[current_idx + 1] or nil
    local previous_chapter = current_idx and not is_full_book and chapters[current_idx - 1] or nil
    local function chapter_id(ch) return ch and tostring(ch.chapterUid or ch.chapterId or '') or nil end
    local current_id,previous_id,next_id=chapter_id(current_chapter),chapter_id(previous_chapter),chapter_id(next_chapter)
    local expected_chapter={book=identity,book_id=tostring(book_id),file=file_path,index=current_idx,
        current=current_id,previous=previous_id,next=next_id}
    local Chapters=require('weread.lib.reader_progress_chapter')
    local ProgressContext=require('weread.lib.reader_progress_context')
    local viewport=(current_idx or is_full_book) and ProgressContext.capture(self)
    local native_previous,native_next
    if viewport and is_full_book and not partial then
        native_previous=Chapters.native_target(viewport,-1)
        native_next=Chapters.native_target(viewport,1)
    end
    local expected_next,still_at_end=expected_chapter,nil
    if at_end and is_full_book and partial then
        local tail=Chapters.combined_end(book,document,proof)
        if tail and chapters[tail+1] then
            local Context=require('weread.lib.source_context')
            local function location() return Context.location(document,reader_ui.view and reader_ui.view.view_mode) end
            local ending=location()
            if ending then
                still_at_end=function() return Context.same_location(ending,location()) end
                expected_next={book=identity,book_id=tostring(book_id),file=file_path,index=tail,
                    current=chapter_id(chapters[tail]),previous=chapter_id(chapters[tail-1]),next=chapter_id(chapters[tail+1]),
                    combined_file=proof.file_id,combined_opf=proof.opf_hash}
            end
        end
    end

    local function show_context_required()
        self:showTransientInfo(
            _("This action requires an open WeRead book."), 1)
    end

    local function chapter_action_current()
        return not self._weread_suspended and valid_reader()
            and self.progress_sync==progress_sync
            and (not progress_sync or progress_sync.generation==sync_generation
                and progress_sync.navigation_generation==navigation_generation)
            and (not viewport or ProgressContext.current(self,viewport))
    end
    local function open_adjacent(direction)
        if not chapter_action_current() then return end
        local local_target=direction<0 and native_previous or direction>0 and native_next
        if local_target then
            if Chapters.native_target(viewport,direction)==local_target then Chapters.move_native(viewport,direction) end
            return
        end
        local available=direction<0 and previous_chapter or direction>0 and (next_chapter or still_at_end)
        if available then
            if direction>0 and still_at_end and not still_at_end() then return end
            local expected=direction>0 and expected_next or expected_chapter
            local ok,fresh,target=pcall(Chapters.resolve,self,expected,direction)
            if chapter_action_current() then
                if ok and fresh and target then self:openReaderChapter(fresh,target)
                else self:showTransientInfo(_('Chapter information changed. Open the quick menu again.'),3) end
            end
        elseif chapters then
            self:showTransientInfo(_(direction<0 and 'You have reached the first chapter.' or 'You have reached the last chapter.'),1)
        elseif not is_regular_weread_book then
            show_context_required()
        end
    end

    -- Keep the reader quick menu in sync with the global display preference.
    -- Document-level matching may be incomplete while chapters are being
    -- prepared, but the user's show/hide choice is still authoritative here.
    local cache = self.settings:get("cache", {})
    local annotations_visible = cache.show_annotations ~= false
    local location=self._native_account_location and require('weread.lib.native_account_location')
    local account=book and self.library_db and self.library_db:accountKey()
    local close_scope=account and search_scope or nil
    local shelf_id=close_scope and is_regular_weread_book and ReadAccess.display_book_id(book_id)
    EndOfBookDialog.show({
        show_chapter_nav = true,
        show_previous_chapter = is_regular_weread_book,
        show_next_chapter = true,
        chapter_list_downloaded = downloaded_only,
        enable_chapter_list = chapters ~= nil or has_saved_chapters,
        enable_previous_chapter = previous_chapter ~= nil or native_previous ~= nil,
        enable_next_chapter = next_chapter ~= nil or still_at_end ~= nil or native_next ~= nil,
        enable_book_details = book ~= nil,
        enable_sync_progress = is_regular_weread_book,
        enable_search_current = type(search) == "table" and type(search.onShowFulltextSearchInput) == "function",
        enable_search_book = is_regular_weread_book and require('weread.lib.read_access').display_book_id(tostring(book_id)) ~= nil,
        enable_search_cached = is_regular_weread_book and require('weread.lib.read_access').display_book_id(tostring(book_id)) ~= nil,
        show_claim_location = location and location.can_claim(self) or false,
        annotations_visible = annotations_visible,
        close_to_home = close_scope~=nil,
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
                and (self._reader_session_gen or 0)==reader_session and same_scope
                and self.settings:get('auth_epoch',0)==search_epoch then
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
            if not valid_reader() then return end
            if chapters then
                local fresh = load_current_book()
                if fresh then self:showChapterList(fresh) end
            elseif downloaded_only then
                show_downloaded_chapters()
            else
                show_context_required()
            end
        end,
        on_previous = function() open_adjacent(-1) end,
        on_next = function() open_adjacent(1) end,
        on_book_details = function()
            if not valid_reader() then return end
            if book then
                self:showCurrentBookDetails()
            else
                show_context_required()
            end
        end,
        on_shelf_status = shelf_id and function()
            if not self._weread_suspended and load_current_book() and self.library_db:accountKey()==account
                and ReadAccess.display_book_id(self:detectWeReadBook())==shelf_id then
                self:showShelfState(shelf_id)
            end
        end or nil,
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
                local function resolve_chapter(direction)
                    return Chapters.resolve(self,expected_chapter,direction)
                end
                require('weread.ui.reader_progress').show(self,{previous=previous_chapter,next=next_chapter,
                    single_chapter=current_idx~=nil and not is_full_book,
                    book=book,chapters=chapters,chapter_index=current_idx,chapter_uid=current_id,
                    native_chapters=not current_idx or is_full_book,is_current=still_current,
                    resolve_chapter=resolve_chapter,open_chapter=self.openReaderChapter})
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
        on_reader_display = function()
            local function current()
                local scope=self.settings.get_auth_scope and self.settings:get_auth_scope()
                local same=search_scope and self.settings:auth_scope_matches(search_scope) or not search_scope and not scope
                return self.ui==reader_ui and reader_ui.document==document and document.file==file_path
                    and (self._reader_session_gen or 0)==reader_session and same
                    and self.settings:get('auth_epoch',0)==search_epoch
            end
            local ok,valid=pcall(current)
            if ok and valid then require('weread.ui.reader_display').show(self,{is_current=current}) end
        end,
        on_read_stats = function()
            self:showReadStats()
        end,
        on_sync_progress = function()
            if not valid_reader() then return end
            if is_regular_weread_book then
                self:onWeReadSyncProgress()
            else
                show_context_required()
            end
        end,
        on_claim_location = function()
            if not valid_reader() then return end
            local saved=location and location.claim(self)
            self:showTransientInfo(saved and _('Local reading position saved for this account.')
                or _('Could not save this reading position.'),3)
        end,
        on_toggle_annotations = function()
            self:toggleAnnotationVisibility()
        end,
        on_close_book = function()
            if not valid_reader() then return end
            require('weread.ui.reader_exit').close(self,reader_ui,close_scope)
        end,
    })
    return true
end

return M
