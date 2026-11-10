package.path = './?.lua;' .. package.path
local resolve = dofile('spec/koreader/owner_viewport_point.lua')
local checks = 0
local function expect(ok, message) checks = checks + 1; assert(ok, message) end
local root = '/body/DocFragment[1]'
local previous, following = root .. '/body/p/text().0', root .. '/body/p/text().1'
local point = root .. '/body/p.0'
local visible, order, next_point, prev_point = true, 0, following, previous
local doc = { info = { doc_height = 1000 } }
function doc:getCurrentPage() return 3 end
function doc:getPageCount() return 10 end
function doc:getCurrentPos() return 200 end
function doc:getXPointer() return point end
function doc:getNextVisibleChar() return next_point end
function doc:getPrevVisibleChar() return prev_point end
function doc:isXPointerInCurrentPage() return visible end
function doc:getPosFromXPointer() return visible and 210 or 900 end
function doc:compareXPointers() return order end
local location = { xpointer = point, view_mode = 'page' }
expect(resolve(doc, location, 100) == following, 'structural origin did not resolve to visible text')
order = 1
expect(resolve(doc, location, 100) == previous, 'visible preceding text at the structural boundary was lost')
prev_point = '/body/DocFragment[0]/body/p/text().0'
expect(resolve(doc, location, 100) == following, 'previous chapter text was borrowed')
visible = false
expect(not pcall(resolve, doc, location, 100), 'a later page was accepted for an image-only viewport')
visible, next_point = true, root .. '/body/img.0'
expect(not pcall(resolve, doc, location, 100), 'non-text next point was accepted')
next_point = nil
expect(not pcall(resolve, doc, location, 100), 'missing text was accepted')
location.xpointer = following
expect(resolve(doc, location, 100) == following, 'existing text point was changed')
location.xpointer, location.view_mode, next_point = point, 'scroll', following
expect(resolve(doc, location, 100) == following, 'scroll caption was lost')
visible = false
expect(not pcall(resolve, doc, location, 100), 'scroll text below the viewport was accepted')
print(('owner_viewport_point_spec: %d checks'):format(checks))
