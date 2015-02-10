local CNearTree = require("init")
local Vector = require("vector")
local rand = require("prob.random")
local util = require("util")
local m = require("mem")

local C = terralib.includec("stdio.h")

local numPoints = 500

local terra test()
	var nearTree : CNearTree.CNearTreeHandle
	CNearTree.CNearTreeCreate(&nearTree, 2, 16)
	var points = [Vector(double[2])].stackAlloc(numPoints, array(0.0, 0.0))
	var indices = [Vector(int)].stackAlloc(numPoints, 0)
	for i=0,numPoints do
		indices(i) = i
		points(i)[0] = [rand.gaussian_sample(double)](0.0, 1.0)
		points(i)[1] = [rand.gaussian_sample(double)](0.0, 1.0)
	end
	for i=0,numPoints do
		CNearTree.CNearTreeInsert(nearTree, [&double](points(i)), indices:getPointer(i))
	end
	CNearTree.CNearTreeCompleteDelayedInsert(nearTree)

	-- for i=0,numPoints do
	-- 	var queryPoint = points(i)
	-- 	var queryPointPtr = [&double](queryPoint)
	-- 	var outPointPtr: &opaque
	-- 	var outIndexPtr : &opaque
	-- 	CNearTree.CNearTreeNearestNeighbor(nearTree, [math.huge], &outPointPtr, &outIndexPtr, queryPointPtr)
	-- 	var outPoint = [&double](outPointPtr)
	-- 	var outIndex = @[&&int](outIndexPtr)
	-- 	C.printf("should be : [%g, %g]  |  got [%g, %g]\n",
	-- 		queryPoint[0], queryPoint[1], outPoint[0], outPoint[1])
	-- 	C.printf("%d\n", @outIndex)
	-- end

	-- Using the k nearest function
	for i=0,numPoints do
		var queryPoint = points(i)
		var queryPointPtr = [&double](queryPoint)

		var outCoords : CNearTree.CVectorHandle
		var outIndexPtrs : CNearTree.CVectorHandle
		CNearTree.CVectorCreate(&outCoords, sizeof([&opaque]), 0)
		CNearTree.CVectorCreate(&outIndexPtrs, sizeof([&opaque]), 0)
		CNearTree.CNearTreeFindKNearest(nearTree, 1, [math.huge], outCoords, outIndexPtrs, queryPointPtr, 0)
		var outPointPtr : &opaque
		var outIndexPtr : &opaque
		CNearTree.CVectorGetElement(outCoords, &outPointPtr, 0)
		CNearTree.CVectorGetElement(outIndexPtrs, &outIndexPtr, 0)
		var outPoint = [&double](outPointPtr)
		var outIndex = @[&&int](outIndexPtr)

		-- var outPointPtr2: &opaque
		-- var outIndexPtr2 : &opaque
		-- CNearTree.CNearTreeNearestNeighbor(nearTree, [math.huge], &outPointPtr2, &outIndexPtr2, queryPointPtr)
		-- var outPoint2 = [&double](outPointPtr2)
		-- var outIndex2 = @[&&int](outIndexPtr2)

		C.printf("should be : [%g, %g]  |  got [%g, %g]\n",
			queryPoint[0], queryPoint[1], outPoint[0], outPoint[1])
		C.printf("%d\n", @outIndex)

		-- C.printf("%p, %p\n", outIndex, outIndex2)
	end

	-- -- Walk through all the coordinates in the tree
	-- var coords : CNearTree.CVectorHandle
	-- CNearTree.CNearTreeCoords(nearTree, &coords)
	-- var size : uint64
	-- CNearTree.CVectorGetSize(coords, &size)
	-- C.printf("%u\n", size)
	-- for i=0,size do
	-- 	var elem = array(-3.14, 3.14)
	-- 	CNearTree.CVectorGetElement(coords, &elem, i)
	-- 	C.printf("[%g, %g]\n", elem[0], elem[1])
	-- end

	-- -- Walk through all the indices in the tree
	-- var indexPtrs : CNearTree.CVectorHandle
	-- CNearTree.CNearTreeObjects(nearTree, &indexPtrs)
	-- var size : uint64
	-- CNearTree.CVectorGetSize(indexPtrs, &size)
	-- C.printf("%u\n", size)
	-- for i=0,size do
	-- 	var elem: &int
	-- 	CNearTree.CVectorGetElement(indexPtrs, &elem, i)
	-- 	C.printf("%d\n", @elem)
	-- end

	m.destruct(points)
	m.destruct(indices)
end
test()
