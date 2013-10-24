local m = terralib.require("mem")
local templatize = terralib.require("templatize")
local inheritance = terralib.require("inheritance")
local Vec = terralib.require("linalg").Vec
local Vector = terralib.require("vector")
local util = terralib.require("util")


local SamplingPattern = templatize(function(real, spaceDim)
	
	local SpaceVec = Vec(real, spaceDim)
	local SamplePattern = Vector(SpaceVec)

	local struct SamplingPatternT {}

	terra SamplingPatternT:__destruct() end
	inheritance.virtual(SamplingPatternT, "__destruct")

	inheritance.purevirtual(SamplingPatternT, "getSamplePattern()", {}->{&SamplePattern})

	return SamplingPatternT

end)


local RegularGridSamplingPattern = templatize(function(real, spaceDim)

	local SpaceVec = Vec(real, spaceDim)
	local CellVec = Vec(uint, spaceDim)
	local SamplePattern = Vector(SpaceVec)
	local SamplingPatternT = SamplingPattern(real, spaceDim)

	local struct RegularGridSamplingPatternT
	{
		storedPattern: SamplePattern
	}
	inheritance.dynamicExtend(SamplingPatternT, RegularGridSamplingPatternT)

	-- Build code to generate list of grid samples using a cartesian product recursion.
	-- Variadic args are coordinates (symbols) for the dimension up to the one we're currently looping over.
	local function buildGridLoop(mins, maxs, numCells, samplePoints, ...)
		local whichDim = select("#",...)
		local coords = {...}
		local function loopBody(coord)
			local newcoords = util.copytable(coords)
			table.insert(newcoords, coord)
			-- Base case: we're at the last dimension
			if whichDim == spaceDim-1 then
				return `[samplePoints]:push(SpaceVec.stackAlloc([coords]))
			-- Recursive case: generate another loop
			else
				return buildGridLoop(mins, maxs, numCells, samplePoints, unpack(newcoords))
			end
		end
		return quote
			for i=0,[numCells][whichDim] do
				var t = (i+0.5)/[numCells][whichDim]  -- Samples at grid cell centroids
				var coord = (1.0-t)*[mins][whichDim] + t*[maxs][whichDim]
				[loopBody(coord)]
			end
		end
	end

	terra RegularGridSamplingPatternT:__construct(mins: SpaceVec, maxs: SpaceVec, numCells: CellVec)
		m.init(self.storedPattern)
		[buildGridLoop(mins, maxs, numCells, self.storedPattern)]
	end

	terra RegularGridSamplingPatternT:__destruct()
		m.destruct(self.storedPattern)
	end
	inheritance.virtual(RegularGridSamplingPatternT, "__destruct")

	terra RegularGridSamplingPatternT:getSamplePattern()
		return &self.storedPattern
	end
	inheritance.virtual(RegularGridSamplingPatternT, "getSamplePattern")

	m.addConstructors(RegularGridSamplingPatternT)
	return RegularGridSamplingPatternT

end)


return
{
	SamplingPattern = SamplingPattern,
	RegularGridSamplingPattern = RegularGridSamplingPattern
}