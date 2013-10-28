local ad = terralib.require("ad")



-- Functions that specify how to quantize/convert color channels
--    from one datatype to another.
local ChannelFns = 
{
	None = function()
		return macro(function(src, dst)
			local DstTyp = [dst]:gettype()
			return `[DstTyp]([src])
		end)
	end,
	Quantize = function()
		return macro(function(src, dst)
			local SrcTyp = src:gettype()
			local DstTyp = dst:gettype()
			if SrcTyp:isintegral() and DstTyp:isfloat() then
				local intmax = 2 ^ (terralib.sizeof(SrcTyp)*8)
				return `[src] / [DstTyp](intmax)
			else if SrcTyp:isfloat() and DstTyp:isintegral() then
				local intmax = 2 ^ (terralib.sizeof(DstTyp)*8)
				return `[DstTyp]([src] * intmax)
			else
				return `[DstTyp]([src])
			end
		end)
	end
}


-- Functions that specify how to deal with 'extra' color channels when
--    writing to/loading from images.
local function makeDimMatchFn(extraCompFn)
	return function(channelFn)
		channelFn = channelFn or ChannelFns.Quantize()
		return macro(function(src, dst)
			local SrcTyp = src:gettype()
			local DstTyp = dst:gettype()
			local SrcDim = SrcTyp.__templateParams[2]
			local DstDim = DstTyp.__templateParams[2]
			local MinDim = math.min(SrcDim, DstDim)
			local t = {}
			for i=1,MinDim do table.insert(t, quote `[dst].entries[ [i-1] ] = channelFn([src].entries[ [i-1] ]) end)
			for i=MinDim+1,DstDim do table.insert(t, quote `[dst].entries[ [i-1] ] = channelFn([extraCompFn(src, SrcDim, DstDim, i)]) end)
		end)
	end
end
local DimensionMatchFns =
{
	makeNew = makeDimMatchFn,
	Zeros = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		return 0.0
	end),
	ZerosWithFullAlpha = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		if currIndex == dstDim then return 1.0 else return 0.0 end
	end),
	RepeatLast = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		return `[src][ [srcDim-1] ]
	end),
	RepeatLastWithFullAlpha = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		if currIndex == dstDim then return 1.0 else return `[src][ [srcDim-1] ] end
	end)
}

-- Functions that specify how to interpolate color from an image
local ImageInterpFns = 
{
	NearestNeighbor = function()
		return macro(function(image, samplePoint)
			return quote
				var i = [uint]([samplePoint].entries[0] * [image]:width())
				var j = [uint]([samplePoint].entries[1] * [image]:height())
				var color = [image]:getPixelColor(i, j)
			in
				color
			end
		end)
	end
}

-- Functions that specify how to interpolate color from a SampledFn
local SampleInterpFns = 
{
	NearestNeighbor = function()
		-- This is really just a flag indicating that we should do nearest neighbor,
		--    intead of general interpolation
		return "NearestNeighbor"
		-- This is what the structure of a general interpolation function should look like:
		--    return macro(function(sampledFn, samplePoint)
		-- 	     --
		--    end)
	end
}

-- Some default color accumlation / clamping functions
-- Can think of these as a different interface to providing the same information as
--    OpenGL's glBlendFunc and glBlendEquation
local AccumFns = 
{
	Replace = function()
		return macro(function(currColor, newColor) return newColor end)
	end,
	Over = function()
		return macro(function(currColor, newColor)
			return `[newColor]:alpha()*[newColor] + (1.0 - [newColor]:alpha())*[currColor]
		end)
	end
}
local ClampFns = 
{
	None = function() return macro(function(color) return color end) end,
	Min = function(maxval)
		if maxval == nil then maxval = 1.0 end
		return macro(function(color)
			local VecT = color:gettype()
			return [VecT.map(color, function(ce) return `ad.math.fmin([ce], maxval) end)]
		end)
	end,
	SoftMin = function(power, maxval)
		if maxval == nil then maxval = 1.0 end
		return macro(function(color)
			local VecT = color:gettype()
			return [VecT.map(color, function(ce)
				-- TODO: More efficient softmin implementation.
				return `ad.math.pow(ad.math.pow([ce], -power) + ad.math.pow(maxval, -power), 1.0/-alpha)
			end)]
		end)
	end
}


return
{
	ChannelFns = ChannelFns,
	DimensionMatchFns = DimensionMatchFns,
	ImageInterpFns = ImageInterpFns,
	SampleInterpFns = SampleInterpFns,
	AccumFns = AccumFns,
	ClampFns = ClampFns
}





