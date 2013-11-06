local m = terralib.require("mem")
local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local templatize = terralib.require("templatize")
local ad = terralib.require("ad")


-- Skip sampling shapes at locations where the resulting alpha
--    would be less than this threshold
local smoothAlphaThresh = 0.02
local logSmoothAlphaThresh = math.log(smoothAlphaThresh)


local ImplicitSampler = templatize(function(SampledFunctionT, Shape)

	assert(SampledFunctionT.ColorVec == Shape.ColorVec)
	assert(SampledFunctionT.SpaceVec.Dimension == Shape.SpaceVec.Dimension)

	local real = Shape.SpaceVec.RealType
	local SamplingPattern = SampledFunctionT.SamplingPattern

	local struct ImplicitSamplerT
	{
		shapes: Vector(&Shape),
		sampledFn: &SampledFunctionT
	}
	ImplicitSamplerT.SampledFunctionType = SampledFunctionT

	terra ImplicitSamplerT:__construct(sampledFn: &SampledFunctionT)
		m.init(self.shapes)
		self.sampledFn = sampledFn
	end

	terra ImplicitSamplerT:__destruct()
		self:clearShapes()
		m.destruct(self.shapes)
	end

	-- Assumes ownership of shape
	terra ImplicitSamplerT:addShape(shape: &Shape)
		self.shapes:push(shape)
	end

	local function buildSampleFunction(smoothing)
		local function accumSharp(self, index, isovalue, color)
			return quote
				if [isovalue] <= 0.0 then [self].sampledFn:accumulateSample([index], [color]) end
			end
		end
		local function accumSmooth(self, index, isovalue, color, smoothParam)
			return quote
				if [isovalue] < -[smoothParam]*logSmoothAlphaThresh then
					var alpha = ad.math.exp(-[isovalue] / [smoothParam])
					[self].sampledFn:accumulateSample([index], [color], alpha)
				end
			end
		end
		local function expandBounds(bounds, smoothParam)
			return quote [bounds]:expand(ad.math.sqrt(-smoothParam*logSmoothAlphaThresh)) end
		end
		local self = symbol(&ImplicitSamplerT, "self")
		local pattern = symbol(&SamplingPattern, "pattern")
		local smoothParam = symbol(real, "smoothParam")
		local params = {self, pattern}
		if smoothing then table.insert(params, smoothParam) end
		return terra([params])
			[self].sampledFn:setSamplingPattern([pattern])
			-- TODO: More efficient than O(#samples*#shapes)
			for shapei=0,[self].shapes.size do
				var shape = [self].shapes:get(shapei)
				var bounds = shape:bounds()
				[smoothing and expandBounds(bounds, smoothParam) or quote end]
				for sampi=0,[pattern].size do
					var samplePoint = [pattern]:getPointer(sampi)
					if bounds:contains(@samplePoint) then
						var isovalue, color = shape:isovalueAndColor(@samplePoint)
						[smoothing and accumSmooth(self, sampi, isovalue, color, smoothParam) or
									   accumSharp(self, sampi, isovalue, color)]
					end
				end
			end
		end
	end

	ImplicitSamplerT.methods.sampleSharp = buildSampleFunction(false)
	ImplicitSamplerT.methods.sampleSmooth = buildSampleFunction(true)

	terra ImplicitSamplerT:clearSamples()
		self.sampledFn:clear()
	end

	terra ImplicitSamplerT:clearShapes()
		for i=0,self.shapes.size do
			m.delete(self.shapes:get(i))
		end
		self.shapes:clear()
	end

	terra ImplicitSamplerT:clear()
		self:clearShapes()
		self:clearSamples()
	end

	m.addConstructors(ImplicitSamplerT)
	return ImplicitSamplerT

end)


return
{
	ImplicitSampler = ImplicitSampler
}



