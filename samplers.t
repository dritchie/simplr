local m = terralib.require("mem")
local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local templatize = terralib.require("templatize")
local shapes = terralib.require("shapes")
local SampledFunction = terralib.require("sampledFunction")


-- Blurring will use the alpha channel (last output dimension), so we'll have to
--    make sure we always use RGBA color, even when A is constant in the input...

local ImplicitSampler = templatize(function(real, spaceDim, colorDim, accumFn, clampFn)

	local Shape = shapes.ImplicitShape(real, spaceDim, colorDim)
	local SpaceVec = Vec(real, spaceDim)
	local ColorVec = Color(real, colorDim)
	local SamplingPattern = Vector(SpaceVec)
	local Samples = Vector(ColorVec)
	local SampledFunctionT = nil
	-- Need to write it this way so that template classes are considered equal where
	--    they ought to be.
	if accumFn and clampFn then
		SampledFunctionT = SampledFunction(real, spaceDim, colorDim, accumFn, clampFn)
	else
		SampledFunctionT = SampledFunction(real, spaceDim, colorDim)
	end

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

	terra ImplicitSamplerT:sample(pattern: &SamplingPattern)
		self.sampledFn:setSamplingPattern(pattern)
		-- TODO: More efficient than O(#samples*#shapes)
		for sampi=0,pattern.size do
			var samplePoint = pattern:getPointer(sampi)
			for shapei=0,self.shapes.size do
				-- TODO: blur would happen here
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