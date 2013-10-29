local m = terralib.require("mem")
local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local templatize = terralib.require("templatize")


-- Blurring will use the alpha channel (last output dimension), so we'll have to
--    make sure we always use RGBA color, even when A is constant in the input...

local ImplicitSampler = templatize(function(SampledFunctionT, Shape)

	assert(SampledFunctionT.ColorVec == Shape.ColorVec)

	local SamplingPattern = SampledFunctionT.SamplingPattern

	local struct ImplicitSamplerT
	{
		shapes: Vector(&Shape),
		sampledFn: &SampledFunctionT
	}

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

	-- ImplicitSamplerT.methods.sample = macro(function(self, pattern, doSmoothing)
	-- 	if doSmoothing == nil then
	-- 		doSmoothing = false
	-- 	else
	-- 		assert(doSmoothing:gettype() == bool)
	-- 		local smooth = doSmoothing:asvalue()
	-- 		assert(smooth)
	-- 	end
	-- 	local function handleSample(index, isovalue, color)
	-- 		if not smooth then
	-- 			return `if [isovalue] < 0.0 then [self].sampledFn:accumulateSample([index], [color]) end
	-- 		else
	-- 			-- Deal with smoothing here
	-- 		end
	-- 	end
	-- 	return quote
	-- 		self.sampledFn:setSamplingPattern(pattern)
	-- 		-- TODO: More efficient than O(#samples*#shapes)
	-- 		for sampi=0,pattern.size do
	-- 			var samplePoint = pattern:getPointer(sampi)
	-- 			for shapei=0,self.shapes.size do
	-- 				var isovalue, color = self.shapes:get(shapei):isovalueAndColor(samplePoint)
	-- 				if isovalue <= 0.0 then
	-- 					self.sampledFn:accumulateSample(sampi, color)
	-- 				end
	-- 			end
	-- 		end
	-- 	end
	-- end)

	terra ImplicitSamplerT:sample(pattern: &SamplingPattern)
		self.sampledFn:setSamplingPattern(pattern)
		-- TODO: More efficient than O(#samples*#shapes)
		for sampi=0,pattern.size do
			var samplePoint = pattern:getPointer(sampi)
			for shapei=0,self.shapes.size do
				var isovalue, color = self.shapes:get(shapei):isovalueAndColor(samplePoint)
				if isovalue <= 0.0 then
					self.sampledFn:accumulateSample(sampi, color)
				end
			end
		end
	end

	terra ImplicitSamplerT:clearSamples()
		self.sampledFn:clear()
	end

	terra ImplicitSamplerT:clearShapes()
		for i=0,self.shapes.size do
			m.delete(self.shapes:get(i))
		end
		self.shapes:clear()
	end

	m.addConstructors(ImplicitSamplerT)
	return ImplicitSamplerT

end)


return
{
	ImplicitSampler = ImplicitSampler
}



