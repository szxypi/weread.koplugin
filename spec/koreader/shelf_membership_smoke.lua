-- Native tri-state membership menu and actual SQLite snapshot transactions.
return function(plugin,home)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local Settings=require('weread.lib.settings');local LuaSettings=require('luasettings')
    local DB=require('weread.lib.library_db')
    local tr=require('weread.lib.i18n').tr
    plugin:closeWeReadUI()
    local root=plugin.settings.data_dir..'/shelf-membership';assert(require('util').makePath(root..'/cache'))
    local data=plugin.client:json_decode(plugin.client:json_encode(plugin.settings.store.data))
    data.books={};data.account={user_vid='910001',name='合成在架状态'};data.cookies={};data.api_key=''
    local settings=setmetatable({data_dir=root,cache_dir=root..'/cache',default_cache_dir=root..'/cache',
        settings_file=root..'/configuration.lua',mock_endpoint=plugin.settings.mock_endpoint},Settings)
    settings.store=LuaSettings:open(settings.settings_file);settings.store.data=data;settings:flush()
    local factory=Settings.new;Settings.new=function() return settings end
    local class=getmetatable(plugin);local ok,host=pcall(class.new,class,{ui=plugin.ui});Settings.new=factory
    assert(ok and host);host.isNetworkOnline=function() return false end
    local db=host.library_db
    local function sql(text)
        local connection=assert(db:open());connection:execsql(text);connection:close()
    end
    local function row(menu,label)
        for _i,item in ipairs(menu.item_table) do if item.text==tr(label) then return item end end
        error('membership native row missing: '..label)
    end
    local function show(id,expected,screenshot)
        assert(host:showShelfState(id));local menu=assert(host._shelf_state_menu)
        assert(row(menu,'In cloud bookshelf').mandatory==tr(expected),'wrong native membership state')
        if screenshot then UIManager:forceRePaint();Screen:shot(home..'/../evidence/'..screenshot..'.png') end
        return menu
    end
    local report={result='UNVERIFIED',synthetic_only=true,cases={},account_requests=0,account_data_writes=0}
    assert(db:getShelfStatus('42').present==nil);show('42','Unknown','shelf-membership-unknown')
    assert(db:putBook({bookId='42',title='合成详情',finishReading=1}))
    assert(db:getShelfStatus('42').present==nil,'detail-only row became on-shelf')
    report.cases.no_snapshot_and_detail_only_unknown=true
    local original={{bookId='42',title='合成在架书',finishReading=0},{bookId='43',title='另一本合成书'}}
    assert(db:cacheShelf(original,{}))
    local entry=db:getShelfStatus('42');assert(entry.present==true and entry.book.finishReading==0)
    local menu=show('42','Yes','shelf-membership-present')
    assert(row(menu,'Finished reading').mandatory==tr('No'))
    report.cases.present_from_complete_snapshot=true
    assert(db:putBook({bookId='44',title='未在架的合成详情',secret=1,finishReading=1}))
    entry=db:getShelfStatus('44');assert(entry.present==false and not entry.book and entry.cached_at>0)
    menu=show('44','No','shelf-membership-absent')
    assert(row(menu,'The last saved bookshelf does not contain this book.') and row(menu,'Private reading').mandatory==tr('Not provided'))
    assert(DB:new(settings):getShelfStatus('44').present==false,'reopening database lost negative evidence')
    report.cases.saved_absence_offline_and_detail_isolation=true
    assert(not db:cacheShelf({{bookId='99'},{}},{}))
    assert(not db:cacheShelf({[1]={bookId='99'},[3]={bookId='100'}},{}))
    assert(not db:cacheShelf({{bookId='99'},{bookId='99'}},{}))
    assert(db:getShelfStatus('42').present==true and db:getShelfStatus('99').present==false)
    report.cases.invalid_snapshots_keep_previous_state=true
    local codec=require('json');local encode=codec.encode
    codec.encode=function(value,...)
        if type(value)=='table' and value.bookId=='99' then return nil end
        return encode(value,...)
    end
    local encoded,accepted=pcall(db.cacheShelf,db,{{bookId='98',title='先写入的合成项'},{bookId='99',title='编码失败的合成项'}},{})
    codec.encode=encode
    assert(encoded and not accepted and db:getShelfStatus('42').present==true and db:getShelfStatus('98').present==false)
    report.cases.nil_encoding_rolls_back_prior_inserts=true
    sql([[CREATE TRIGGER stop_membership_insert BEFORE INSERT ON shelf_state
        WHEN NEW.name='membership_snapshot' BEGIN SELECT RAISE(ABORT,'synthetic save failure'); END]])
    assert(not db:cacheShelf({{bookId='99',title='不应提交'}},{{archiveId='7',name='不应提交',bookIds={'99'}}}))
    sql('DROP TRIGGER stop_membership_insert')
    assert(db:getShelfStatus('42').present==true and db:getShelfStatus('99').present==false)
    assert(#db:getShelfArchives()==0,'failed snapshot committed archives separately')
    report.cases.transaction_failure_rolls_back_books_marker_and_archives=true
    sql("UPDATE books SET payload='broken-payload' WHERE book_id='42'")
    entry=db:getShelfStatus('42');assert(entry.present==true and not entry.book)
    menu=show('42','Yes');assert(row(menu,'Saved status fields are unavailable for this book.'))
    report.cases.unreadable_payload_does_not_become_absent=true
    assert(db:cacheShelf({},{}));assert(db:getShelfStatus('42').present==false)
    show('42','No');report.cases.complete_empty_snapshot_is_known=true
    assert(db:cacheShelf(original,{}));sql("DELETE FROM shelf_state WHERE name='membership_snapshot'")
    assert(db:getShelfStatus('42').present==true and db:getShelfStatus('99').present==nil)
    show('42','Yes');show('99','Unknown');report.cases.legacy_negative_requires_refresh=true
    sql([[INSERT INTO shelf_state(name,payload) VALUES('membership_snapshot','broken-marker')]])
    assert(db:getShelfStatus('42').present==nil and db:getShelfStatus('99').present==nil)
    show('99','Unknown');report.cases.invalid_marker_is_unknown=true
    assert(db:cacheShelf(original,{}));sql("DELETE FROM books WHERE book_id='43'")
    assert(db:getShelfStatus('42').present==nil and db:getShelfStatus('43').present==nil)
    report.cases.inconsistent_marker_count_is_unknown=true
    assert(db:cacheShelf(original,{}));host:closeWeReadUI()
    settings:set('account',{user_vid='910002'});settings:flush()
    assert(db:getShelfStatus('42').present==nil);show('42','Unknown')
    host:onWeReadAccountChanged();assert(not host._shelf_state_menu)
    settings:set('account',{user_vid='910001'});settings:flush()
    assert(db:getShelfStatus('42').present==true);show('42','Yes')
    report.cases.account_switch_and_return=true
    host:closeWeReadUI();report.result='PASS'
    local file=assert(io.open(home..'/../evidence/shelf-membership.json','wb'))
    file:write(plugin.client:json_encode(report));file:close()
    print('PASS: shelf membership SQLite -> yes/no/unknown, empty/legacy/malformed snapshots, atomic rollback, offline native menu and account isolation')
end
