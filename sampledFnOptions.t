local ad = require("ad")
local Color = require("Color")


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
				return quote
					[dst] = [DstTyp](ad.math.fmin(ad.math.fmax([src] * intmax, 0.0), intmax))
				end
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
			local ImageType = image:gettype().type
			local ColorVec = ImageType.ColorVec
			return quote
				var i = [int]([samplePoint].entries[0] * [image]:width())
				var j = [int]([samplePoint].entries[1] * [image]:height())
				var color : ColorVec
				if i >=0 and i < [image]:width() and j >= 0 and j < [image]:height() then
					color = [image]:getPixelColor(i, j)
				else
					-- If samplePoint outside of image bounds, then just return black
					-- TODO: Be able to specify a 'default' color?
					color:__construct()
				end
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

-- AD primitive for the over operator
local val = ad.val
local accumadj = ad.def.accumadj
local over = ad.def.makePrimitive(
	terra(curr: double, new: double, alpha: double)
		return (1.0-alpha)*curr + alpha*new
	end,
	function(T1, T2, T3)
		return terra(v: ad.num, curr: T1, new: T2, alpha: T3)
			accumadj(v, alpha(), val(new()) - val(curr()))
			accumadj(v, new(), val(alpha()))
			accumadj(v, curr(), 1.0 - val(alpha()))
		end
	end)

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
			local VecT = currColor:gettype()
			return
				`[VecT.zip(currColor, newColor, function(c, n)
					-- return `[alpha]*n + (1.0 - [alpha])*c
					return `over(c, n, [alpha])
				end)]
			-- return `[alpha]*[newColor] + (1.0 - [alpha])*[currColor]
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
		maxval = `[double](maxval)
		return macro(function(color)
			local VecT = color:gettype()
			return `[VecT.map(color, function(ce) return `ad.math.fmin([ce], maxval) end)]
		end)
	end,
	SoftMin = function(power, maxval)
		if maxval == nil then maxval = 1.0 end
		local minuspower = -power
		local invminuspower = 1.0/minuspower
		local innerTerm = math.pow(maxval, minuspower)
		return macro(function(color)
			local VecT = color:gettype()
			return `[VecT.map(color, function(ce)
				return `ad.math.pow(ad.math.pow([ce], minuspower) + innerTerm, invminuspower)
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





