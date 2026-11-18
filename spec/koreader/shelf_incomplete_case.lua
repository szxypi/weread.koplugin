-- A partial shelf must not replace the complete, account-scoped SQLite cache.
return function(host)
    local db=host.library_db
    local saved={fetch=host.client.get_shelf,login=host.requireShelfLogin,connected=host.isNetworkConnected,
        worker=host.shelf_refresh_worker,info=host.showInfo,notice=host.showTransientInfo,
        cache=db.cacheShelf,books=db.getShelf,archives=db.getShelfArchives,progress=host.prepareShelfProgress}
    local old_books=assert(db:getShelf());local old_groups=assert(db:getShelfArchives())
    local wire=require('weread.lib.shelf_wire')
    assert(wire.valid(host.client,host.client:json_decode('{"books":[],"archive":[]}')))
    assert(not wire.valid(host.client,host.client:json_decode('{"books":[],"archive":{}}')))
    assert(not wire.valid(host.client,host.client:json_decode('{"books":[],"archive":[{"bookIds":{}}]}')))
    local fresh={{bookId='SYN-INCOMPLETE',title='合成临时书籍',readUpdateTime=2000000000}}
    local writes,info,notice=0
    host.requireShelfLogin=function() return true end
    host.isNetworkConnected=function() return true end
    host.client.get_shelf=function() return {books=fresh,_shelf_source='native'} end
    host.shelf_refresh_worker={start=function(_self,task,callback) callback(task());return true end,cancel=function() end}
    host.showInfo=function(_self,message) info=message end
    host.showTransientInfo=function(_self,message) notice=message end
    host.prepareShelfProgress=false
    db.cacheShelf=function(self,...) writes=writes+1;return saved.cache(self,...) end
    host:closeWeReadUI();host:applyShelfSnapshot(old_books,old_groups)
    host.shelf_group_key='archive:1';host:showShelfView('books')
    local prior=assert(host.shelf_view);prior.on_refresh()
    assert(host.shelf_view==prior and host.shelf_group_key=='archive:1' and writes==0 and info,
        'partial response replaced a grouped view')
    local books,groups=db:getShelf(),db:getShelfArchives()
    assert(#books==#old_books and #groups==#old_groups and books[1].bookId==old_books[1].bookId,
        'partial response replaced persisted shelf or groups')
    local observed
    host:refreshBookshelf(nil,{on_loaded=function(ok,snapshot,incomplete) observed={ok,snapshot,incomplete} end})
    assert(observed and observed[1] and observed[3] and #observed[2].books==#old_books and writes==0,
        'home refresh did not retain the complete cache')
    local transient={books=old_books,archives=old_groups}
    assert(require('weread.lib.volatile_shelf').remember(host,transient,{_shelf_source='native'}))
    observed=nil
    host:refreshBookshelf(nil,{on_loaded=function(ok,snapshot,incomplete) observed={ok,snapshot,incomplete} end})
    assert(observed and observed[1]==false and observed[2]==transient and observed[3] and writes==0,
        'an unsaved complete shelf was mistaken for a persisted snapshot')
    require('weread.lib.volatile_shelf').clear(host)
    db.getShelfArchives=function() return nil end
    db.getShelf=function() return {} end
    local first
    host:refreshBookshelf(nil,{on_loaded=function(ok,snapshot,incomplete) first={ok,snapshot,incomplete} end})
    assert(first and first[1]==false and first[3] and first[2].groups_incomplete
        and first[2].books[1].bookId=='SYN-INCOMPLETE' and writes==0,
        'first incomplete response was not temporary')
    host:closeWeReadUI();host:showBookshelf()
    assert(host.shelf_view.books[1].bookId=='SYN-INCOMPLETE' and notice,
        'temporary shelf was not available with an incomplete-data notice')
    host:closeWeReadUI();require('weread.lib.volatile_shelf').clear(host)
    db.cacheShelf,db.getShelf,db.getShelfArchives=saved.cache,saved.books,saved.archives
    host.client.get_shelf,host.requireShelfLogin,host.isNetworkConnected=saved.fetch,saved.login,saved.connected
    host.shelf_refresh_worker,host.showInfo,host.showTransientInfo=saved.worker,saved.info,saved.notice
    host.prepareShelfProgress=saved.progress
    return true
end
