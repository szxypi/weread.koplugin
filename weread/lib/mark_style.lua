-- Official public reader enum; updateBookmark independently verified by the
-- four-write Python trial before native integration. Colors are preserved.
local M={values={0,1,2},labels={[0]='Straight underline',[1]='Marker highlight',[2]='Wavy underline'}}
function M.valid(style) return type(style)=='number' and style%1==0 and style>=0 and style<=2 end
function M.editable(row)
    return type(row)=='table' and row.type==1 and type(row.colorStyle)=='number'
        and row.colorStyle%1==0 and row.colorStyle>=0 and row.colorStyle<=5
end
return M
