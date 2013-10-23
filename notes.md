
### Linear Algebra stuff ###
* Vec(real, dim)
    * 'real' is real number type (e.g. double)
* Mat(real, rowDim, colDim)


### SampledFn(inDim, outDim, real) ###
* Just stores a list of (Vec(real, inDim), Vec(real, outDim) samples
* inDim == 2 version can save itself to an image by (nearest-neighbor) interpolation onto a grid
* (Question) We'll need to do operations that scan over two SampledFns in lockstep. How to enforce that/determine whether two SampledFns have the same set of sample points in the same order?


### ImplicitShape(spaceDim, colorDim, real) ###
* Concrete subclasses have a function taking Vec(real, spaceDim) and return both the isovalue at that point (a real) and the color at that point (a Vec(real, colorDim)).
* (Eventually) Also provide a function to return a bounding polygon for a particular isovalue?


### ImplicitSampler(spaceDim, colorDim, real) ###
* Has a list of ImplicitShape(spaceDim, colorDim, real).
* Samples each one at some set of Vec(real, spaceDim) sample points, storing the result in a SampeldFn(spaceDim, colorDim, real)
* (Question) How to specify sampling patterns to ImplicitSampler?


### (Eventually) ImplicitRenderer(colorDim, real) ###
* No need for 'spaceDim' type parameter, since we know this is 3D -> 2D
* This is a subclass(?) of ImplicitSampler
* Instead of sampling at 2D points, it constructs rays through 2D points. So ImplicitShape will eventually also need a method for returning an (isovalue,color) pair for rays as well as points (by computing the point along the ray with the smallest isovalue)
