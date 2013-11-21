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

-- AD primitive for isovalue smoothing calculations
local val = ad.val
local accumadj = ad.def.accumadj
local smoothAlpha = ad.def.makePrimitive(
	terra(isoval: double, smoothParam: double)
		return ad.math.exp(-isoval / smoothParam)
	end,
	function(T1, T2)
		return terra(v: ad.num, isoval: T1, smoothParam: T2)
			var spv = val(smoothParam())
			accumadj(v, isoval(), -val(v)/spv)
			accumadj(v, smoothParam, val(v)*val(isoval())/(spv*spv))
		end
	end)

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
				var sp = [smoothParam]
				var spv = ad.val(sp)
				var ivv = ad.val([isovalue])
				if ivv < -spv*logSmoothAlphaThresh then
					-- var alpha = ad.math.exp(-[isovalue] / sp)
					var alpha = smoothAlpha([isovalue], sp)
					[self].sampledFn:accumulateSample([index], [color], alpha)
				end
			end
		end
		local function expandBounds(bounds, smoothParam)
			return quote [bounds]:expand(ad.math.sqrt(-smoothParam*logSmoothAlphaThresh)) end
		end
		local self = symbol(&ImplicitSamplerT, "self")
		local pattern = symbol(&SamplingPattern, "pattern")
		local smoothParam = symbol(double, "smoothParam")
		local params = {self, pattern}
		if smoothing then table.insert(params, smoothParam) end
		return terra([params])
			[self].sampledFn:setSamplingPattern([pattern])
			for shapei=0,[self].shapes.size do
				var shape = [self].shapes:get(shapei)
				var bounds = shape:bounds()
				[smoothing and expandBounds(bounds, smoothParam) or quote end]
				for sampi=0,[pattern].size do
					var samplePoint = [pattern]:getPointer(sampi)
					if bounds:contains(samplePoint) then
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



