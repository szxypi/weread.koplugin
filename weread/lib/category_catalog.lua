-- Public hierarchy only. No account identifiers, cookies, queries or books.
local Data=require('weread.lib.discovery_data')
local M={MAX_NODES=5000,MAX_PAYLOAD=1024*1024};M.__index=M
local function fail(kind) error('category_catalog/'..kind,0) end
local function array(value)
    if type(value)~='table' then return false end
    for key in pairs(value) do if type(key)~='number' or key<1 or key%1~=0 or key>#value then return false end end
    return true
end
local function title(value)
    return type(value)=='string' and value~='' and #value<=4096 and not value:find('[%z%c]')
end
function M.validate(value)
    if type(value)~='table' or value.schema~=1 or type(value.loaded_at)~='number'
        or value.loaded_at<1 or value.loaded_at%1~=0 or value.loaded_at>2^53 then fail('snapshot_invalid') end
    local count,visited=0,{}
    local function rows(entries,depth,expected_rank)
        if not array(entries) or depth>8 and #entries>0 or visited[entries] then fail('snapshot_invalid') end
        visited[entries]=true
        local out={}
        for _,row in ipairs(entries) do
            count=count+1
            if count>M.MAX_NODES then fail('limit') end
            if type(row)~='table' or type(row.id)~='string' or #row.id>128 or not row.id:match('^[%w_-]+$')
                or not title(row.title) or type(row.rank)~='boolean' or row.rank~=(row.id:match('^%d+$')==nil)
                or expected_rank~=nil and row.rank~=expected_rank then fail('snapshot_invalid') end
            out[#out+1]={id=row.id,title=row.title,rank=row.rank,children=rows(row.children,depth+1)}
        end
        return out
    end
    local result={schema=1,loaded_at=value.loaded_at,ranks=rows(value.ranks,0,true),categories=rows(value.categories,0,false)}
    if count==0 then fail('empty') end
    return result
end
function M.project(value,now)
    if type(value)~='table' or not array(value.data) then fail('shape') end
    for _,key in ipairs({'errCode','errcode'}) do
        if value[key]~=nil and tonumber(value[key])~=0 then fail('rejected') end
    end
    if value.succ~=nil and value.succ~=true and tonumber(value.succ)~=1 then fail('rejected') end
    local count,visited=0,{}
    local function bound(rows,depth)
        if not array(rows) or depth>16 or visited[rows] then fail('shape') end
        visited[rows]=true
        for _,row in ipairs(rows) do
            count=count+1;if count>M.MAX_NODES then fail('limit') end
            if type(row)=='table' then
                if row.title~=nil and (type(row.title)~='string' or #row.title>4096 or row.title:find('[%z%c]')) then fail('title') end
                for _,key in ipairs({'categories','sublist'}) do if row[key]~=nil then bound(row[key],depth+1) end end
            end
        end
    end
    bound(value.data,0)
    local result=Data.categories(value);result.schema=1;result.loaded_at=now or os.time()
    return M.validate(result)
end
local function close(value) if value then pcall(value.close,value) end end
local function run(self,task)
    if type(self.directory)~='string' or self.directory=='' then return nil end
    local ok,db,stmt
    ok,db=pcall(function() return require('lua-ljsqlite3/init').open(self.directory..'/bookstore-public.db') end)
    if not ok or not db then return nil end
    local result
    ok,result=pcall(function()
        db:exec('PRAGMA busy_timeout=1000')
        db:exec([[CREATE TABLE IF NOT EXISTS category_catalog (
            id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL, updated_at INTEGER NOT NULL
        )]])
        return task(function(sql) stmt=db:prepare(sql);return stmt end)
    end)
    close(stmt);close(db)
    return ok and result or nil
end
function M:new(settings,codec)
    return setmetatable({directory=settings.data_dir,codec=codec},self)
end
function M:read()
    return run(self,function(prepare)
        local row=prepare('SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END, updated_at FROM category_catalog WHERE id=1')
            :bind(M.MAX_PAYLOAD):step()
        if not row or type(row[1])~='string' or #row[1]>M.MAX_PAYLOAD then return nil end
        local value=M.validate(self.codec:json_decode(row[1]))
        if value.loaded_at~=tonumber(row[2]) then return nil end
        return value
    end)
end
function M:write(value)
    local ok,bounded=pcall(M.validate,value)
    if not ok then return false end
    local encoded,payload=pcall(self.codec.json_encode,self.codec,bounded)
    if not encoded or type(payload)~='string' or #payload>M.MAX_PAYLOAD then return false end
    return run(self,function(prepare)
        prepare([[INSERT INTO category_catalog(id,payload,updated_at) VALUES(1,?,?)
            ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at]])
            :bind(payload,bounded.loaded_at):step()
        return true
    end)==true
end
return M
