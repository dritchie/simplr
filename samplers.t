local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local templatize = terralib.require("templatize")
local shapeColor = terralib.require("shapeColor")
local sfn = terralib.require("sampledFn")
local SampledFunctionBase = sfn.SampledFunctionBase


-- Blurring will use the alpha channel (last output dimension), so we'll have to
--    make sure we always use RGBA color, even when A is constant in the input...

local ImplicitSampler = templatize(function(real, spaceDim, colorDim)

	local Shape = shapeColor.ColoredImplicitShape(real, spaceDim, colorDim)
	local SpaceVec = Vec(real, spaceDim)
	local ColorVec = Color(real, colorDim)
	local SamplingPattern = Vector(SpaceVec)
	local Samples = Vector(ColorVec)
	local SampledFunctionT = SampledFunctionBase(real, spaceDim, colorDim)

	local struct ImplicitSamplerT
	{
		shapes: Vector(&Shape),
		sampledFn: &SampledFunctionT
	}

	-- Assumes ownership of sampledFn
	terra ImplicitSamplerT:__construct(sampledFn: &SampledFunctionT)
		m.init(self.shapes)
		self.sampledFn = sampledFn
	end

	terra ImplicitSamplerT:__destruct()
		m.destruct(self.shapes)
		m.delete(self.sampledFn)
	end

	-- Assumes ownership of shape
	terra ImplicitSamplerT:addShape(shape: &Shape)
		self.shapes:push(shape)
	end

	terra ImplicitSamplerT:sample(pattern: &SamplingPattern)
		self.sampledFn:setSamplingPattern(pattern)
		-- TODO: More efficient than O(#samples*#shapes)
		for sampi=0,pattern.size do
			var samplePoint = pattern:get(sampi)
			for shapei=0,self.shapes.size do
				-- TODO: blur would happen here
				var isovalue, color = self.shapes:get(shapei):isovalueAndColor(samplePoint)
				self.sampledFn:accumulateSample(sampi, color)
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