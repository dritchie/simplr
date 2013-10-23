local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local templatize = terralib.require("templatize")


local SampledFunction = templatize(function(real, inDim, outDim)
	
	local InVec = Vec(real, inDim)
	local OutVec = Vec(real, outDim)
	local SamplingPattern = Vector(InVec)
	local Samples = Vector(OutVec)

	local struct SampledFunctionT = 
	{
		samplingPattern: &SamplingPattern,
		samples: Samples
	}

	terra SampledFunctionT:__construct()
		self.samplingPattern = nil
		m.init(self.samples)
	end

	terra SampledFunctionT:__copy(other: &SampledFunctionT)
		self.samples = m.copy(other.samples)
	end

	terra SampledFunctionT:__destruct()
		m.destruct(self.samples)
	end

	terra SampledFunctionT:clear()
		self.samplingPattern = nil
		self.samples:clear()
	end

	terra SampledFunctionT:setSamplingPattern(pattern: &SamplingPattern)
		self.samplingPattern = pattern
		self.samples:resize(pattern.size)
	end

	terra SampledFunctionT:setSample(which: uint, value: OutVec)
		self.samples:set(which, value)
	end

	m.addConstructors(SampledFunctionT)
	return SampledFunctionT

end)


return 
{
	SampledFunction = SampledFunction
}
