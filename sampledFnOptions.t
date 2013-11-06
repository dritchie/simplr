local ad = terralib.require("ad")
local Color = terralib.require("Color")


-- Functions that specify how to quantize/convert color channels
--    from one datatype to another.
local ChannelFns = 
{
	None = function()
		return macro(function(src, dst)
			local DstTyp = dst:gettype()
			return quote [dst] = [DstTyp]([src]) end
		end)
	end,
	Quantize = function()
		return macro(function(src, dst)
			local DstTyp = dst:gettype()
			local SrcTyp = src:gettype()
			if SrcTyp:isintegral() and DstTyp:isfloat() then
				local intmax = 2 ^ (terralib.sizeof(SrcTyp)*8) - 1
				return quote [dst] = [src] / [DstTyp](intmax) end
			elseif SrcTyp:isfloat() and DstTyp:isintegral() then
				local intmax = 2 ^ (terralib.sizeof(DstTyp)*8) - 1
				return quote [dst] = [DstTyp]([src] * intmax) end
			else
				return quote [dst] = [DstTyp]([src]) end
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
			-- src is a Color by value, dst is a Color pointer (so we can write into it)
			local SrcTyp = src:gettype()
			local DstTyp = dst:gettype().type
			local SrcDim = SrcTyp.__templateParams[2]
			local DstDim = DstTyp.__templateParams[2]
			local MinDim = math.min(SrcDim, DstDim)
			local t = {}
			for i=1,MinDim do
				local srce = `[src].entries[ [i-1] ]
				local dste = `[dst].entries[ [i-1] ]
				table.insert(t, `channelFn([srce], [dste]))
			end
			for i=MinDim+1,DstDim do
				local dste = `[dst].entries[ [i-1] ]
				table.insert(t, `channelFn([extraCompFn(src, SrcDim, DstDim, i)], [dste]))
			end
			return t
		end)
	end
end
local DimensionMatchFns =
{
	makeNew = makeDimMatchFn,
	Zeros = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		return `0.0
	end),
	RepeatLast = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		return `[src].entries[ [srcDim-1] ]
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
		return macro(function(currColor, newColor, alpha)
			return `[alpha]*[newColor] + (1.0 - [alpha])*[currColor]
		end)
	end,
	Sum = function()
		return macro(function(currColor, newColor) return `currColor + newColor end)
	end,
	Max = function()
		return macro(function(currColor, newColor)
			return `[currColor]:max([newColor])
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
			return `[VecT.map(color, function(ce) return `ad.math.fmin([ce], maxval) end)]
		end)
	end,
	SoftMin = function(power, maxval)
		if maxval == nil then maxval = 1.0 end
		local minuspower = -power
		local invminuspower = 1.0/minuspower
		return macro(function(color)
			local VecT = color:gettype()
			return `[VecT.map(color, function(ce)
				return `ad.math.pow(ad.math.pow([ce], minuspower) + ad.math.pow(maxval, minuspower), invminuspower)
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





