
local source = debug.getinfo(1, "S").source
source = source:gsub("@", ""):gsub("init.t", "")

return terralib.includecstring([[
#include "CVector.c"
#include "CNearTree.c"
#include "CNearTreeTest.c"
]],
"-I", source,
"-D", "USE_LOCAL_HEADERS", 
"-w")