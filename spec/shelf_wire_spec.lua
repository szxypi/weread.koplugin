package.path='./?.lua;'..package.path
local Wire=require('weread.lib.shelf_wire')
local array_mt={}
local client={json_decode=function(_,raw) assert(raw=='[]');return setmetatable({},array_mt) end}
local function array(items) return setmetatable(items or {},array_mt) end
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
expect(Wire.valid(client,{books=array(),archive=array()}),'empty arrays were rejected')
expect(not Wire.valid(client,{books={},archive=array()}),'empty books object was accepted')
expect(not Wire.valid(client,{books=array(),archive={}}),'empty archive object was accepted')
expect(Wire.valid(client,{books={{bookId='41'}},archive={{archiveId='1',bookIds=array()}}}),'empty group array was rejected')
expect(not Wire.valid(client,{books={{bookId='41'}},archive={{archiveId='1',bookIds={}}}}),'empty group object was accepted')
expect(Wire.valid(client,{books={{bookId='41'}},archive={{archiveId='1',bookIds={'41'}}}}),'nonempty groups were rejected')
print('shelf_wire_spec: '..checks..' checks')
