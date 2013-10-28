local m = terralib.require("mem")
local templatize = terralib.require("templatize")
local util = terralib.require("util")
local Color = terralib.require("color")

local FI = os.getenv("FREEIMAGE_H_PATH") and terralib.includec(os.getenv("FREEIMAGE_H_PATH")) or
		   error("Environment variable 'FREEIMAGE_H_PATH' not defined.")
if os.getenv("FREEIMAGE_LIB_PATH") then
	terralib.linklibrary(os.getenv("FREEIMAGE_LIB_PATH"))
else
	error("Environment variable 'FREEIMAGE_LIB_PATH' not defined.")
end

-- local C = terralib.includec("stdio.h")

FI.FreeImage_Initialise(0)
-- Tear down FreeImage only when it is safe to destroy this module
local struct FIMemSentinel {}
terra FIMemSentinel:__destruct()
	-- C.printf("FreeImage deinit\n")
	FI.FreeImage_DeInitialise()
end
local __fiMemSentinel = terralib.new(FIMemSentinel)
m.gc(__fiMemSentinel)


local function makeEnum(names, startVal)
	local enum = {}
	for i,n in ipairs(names) do
		enum[n] = startVal + (i-1)
	end
	return enum
end

-- FreeImage types
local Type = makeEnum({"UNKNOWN", "BITMAP", "UINT16", "INT16", "UINT32", "INT32", "FLOAT", "DOUBLE", "COMPLEX", "RGB16",
	"RGBA16", "RGBF", "RGBAF"}, 0)

-- FreeImage formats
local Format = makeEnum({"UNKNOWN", "BMP", "ICO", "JPEG", "JNG", "KOALA", "LBM", "IFF", "MNG", "PBM", "PBMRAW",
	"PCD", "PCX", "PGM", "PGMRAW", "PNG", "PPM", "PPMRAW", "RAS", "TARGA", "TIFF", "WBMP", "PSD", "CUT", "XBM", "XPM",
	"DDS", "GIF", "HDR", "FAXG3", "SGI", "EXR", "J2K", "JP2", "PFM", "PICT", "RAW"}, -1)

local function bytesToBits(bytes) return bytes*8 end
local function typeAndBitsPerPixel(dataType, numChannels)
	assert(numChannels > 0 and numChannels <= 4)
	-- 8-bit per channel image (standard bitmaps)
	if dataType == uint8 then
		return Type.BITMAP, bytesToBits(terralib.sizeof(uint8)*numChannels)
	-- Signed 16-bit per channel image (only supports single channel)
	elseif dataType == int16 and numChannels == 1 then
		return Type.INT16, bytesToBits(terralib.sizeof(int16))
	-- Unsigned 16-bit per channel image
	elseif dataType == uint16 then
		local s = terralib.sizeof(uint16)
		-- Single-channel
		if numChannels == 1 then
			return Type.UINT16, bytesToBits(s)
		-- RGB
		elseif numChannels == 3 then
			return Type.RGB16, bytesToBits(s*3)
		-- RGBA
		elseif numChannels == 4 then
			return Type.RGBA16, bytesToBits(s*4)
		end
	-- Signed 32-bit per channel image (only supports single channel)
	elseif dataType == int32 and numChannels == 1 then
		return Type.INT32, bytesToBits(terralib.sizeof(int32))
	-- Unsigned 32-bit per channel image (only supports single channel)
	elseif dataType == uin32 and numChannels == 1 then
		return Type.UINT32, bytesToBits(terralib.sizeof(uint32))
	-- Single precision floating point per chanel image
	elseif dataType == float then
		local s = terralib.sizeof(float)
		-- Single-channel
		if numChannels == 1 then
			return Type.FLOAT, bytesToBits(s)
		-- RGB
		elseif numChannels == 3 then
			return Type.RGBF, bytesToBits(s*3)
		-- RGBA
		elseif numChannels == 4 then
			return Type.RGBAF, bytesToBits(s*4)
		end
	-- Double-precision floating point image (only supports single channel)
	elseif dataType == double then
		return Type.DOUBLE, bytesToBits(terralib.sizeof(double))
	else
		error(string.format("FreeImage does not support images with %u %s's per pixel", numChannels, tostring(dataType)))
	end
end

-- Code gen helper
local function arrayElems(ptr, num)
	local t = {}
	for i=1,num do
		local iminus1 = i-1
		table.insert(t, `ptr[iminus1])
	end
	return t
end

local Image = templatize(function(dataType, numChannels)
	
	local fit, bpp = typeAndBitsPerPixel(dataType, numChannels)
	local ColorVec = Color(dataType, numChannels)

	local struct ImageT
	{
		fibitmap: &FI.FIBITMAP
	}
	ImageT.DataType = dataType
	ImageT.NumChannels = numChannels
	ImageT.ColorVec = ColorVec
	ImageT.FreeImageType = fit
	ImageT.BitsPerPixel = bpp

	terra ImageT:__construct(width: uint, height: uint)
		self.fibitmap = FI.FreeImage_AllocateT(fit, width, height, bpp, 0, 0, 0)
	end

	terra ImageT:__construct(format: int, filename: rawstring)
		self.fibitmap = FI.FreeImage_Load(format, filename, 0)
		-- C.printf("mine - fit: %u, bpp: %u\n", fit, bpp)
		-- C.printf("file - fit: %u, bpp: %u\n", FI.FreeImage_GetImageType(self.fibitmap), FI.FreeImage_GetBPP(self.fibitmap))
		if not (fit == FI.FreeImage_GetImageType(self.fibitmap) and
				bpp == FI.FreeImage_GetBPP(self.fibitmap)) then
			FI.FreeImage_Unload(self.fibitmap)
			util.fatalError("image file '%s' does not contain %u %s's per pixel\n", filename, numChannels, [tostring(dataType)])
		end
	end

	terra ImageT:__destruct()
		FI.FreeImage_Unload(self.fibitmap)
		self.fibitmap = nil
	end

	terra ImageT:width() return FI.FreeImage_GetWidth(self.fibitmap) end
	util.inline(ImageT.methods.width)

	terra ImageT:height() return FI.FreeImage_GetHeight(self.fibitmap) end
	util.inline(ImageT.methods.height)

	terra ImageT:pixelData(i: uint, j: uint) : &dataType
		return ([&dataType](FI.FreeImage_GetScanLine(self.fibitmap, j)))+(numChannels*i)
	end
	util.inline(ImageT.methods.pixelData)

	terra ImageT:getPixelColor(i: uint, j: uint)
		var cvec = ColorVec.stackAlloc()
		var pixelData = self:pixelData(i, j)
		[ColorVec.entries(cvec)] = [arrayElems(pixelData)]
		return cvec
	end
	util.inline(ImageT.methods.getPixelColor)

	terra ImageT:setPixelColor(i: uint, j: uint, color: ColorVec)
		var pixelData = self:pixelData(i, j)
		[arrayElems(pixelData)] = [ColorVec.entries(cvec)]
	end
	util.inline(ImageT.methods.setPixelColor)

	m.addConstructors(ImageT)
	return ImageT

end)


return
{
	Type = Type,
	Format = Format,
	Image = Image,
	__fiMemSentinel = __fiMemSentinel
}







