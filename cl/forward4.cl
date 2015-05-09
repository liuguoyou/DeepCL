// Copyright Hugh Perkins 2014, 2015 hughperkins at gmail
//
// This Source Code Form is subject to the terms of the Mozilla Public License, 
// v. 2.0. If a copy of the MPL was not distributed with this file, You can 
// obtain one at http://mozilla.org/MPL/2.0/.

// expected defines:
// BIASED (or not)

void copyLocal( local float *target, global float const *source, int N ) {
    int numLoops = ( N + get_local_size(0) - 1 ) / get_local_size(0);
    for( int loop = 0; loop < numLoops; loop++ ) {
        int offset = loop * get_local_size(0) + get_local_id(0);
        if( offset < N ) {
            target[offset] = source[offset];
        }
    }
}

#ifdef gOutputImageSize // for previous tests that dont define it
// workgroup id organized like: [n][filterid]
// local id organized like: [outrow][outcol]
// each thread iterates over: [upstreamplane][filterrow][filtercol]
// number workgroups = 32
// one filter plane takes up 5 * 5 * 4 = 100 bytes
// one filter cube (corresponding to one outplane) = 5*5 * 32 * 4 = 3.2KB (ok)
// all filter cubes = 3.2KB * 32 = 102KB (too big)
// output are organized like [n][filterid][outrow][outcol]
// the pixels per thread thing... :
// - we have one thread (~= cuda core) per output value,
//   ie one thread for each combination of [outrow][outcol]
// - however, the number of threads is typically limited on a gpu,
//   eg to 512 (eg Intel HD), or 1024 (eg nVidia K520)
// - so what happens if the number of output points is larger than
//   the maximum workgroup size?
// - then we have several possibilities really:
//   - we can divide the image into blocks, and process each block
//     separately.  This is probably a good option, but fair amount of
//     work
//   - we can get each thread to handle more than one output
//     pixel, by looping
//   - we can consider the output image in 1d, by putting the rows
//     one after another, and assign each contiguous workgroup-size
//     block to one workgroup
//     => this is how this kernel works
//     basically, it's a hack, so larger images actually run, without
//     crashing, and we can probably improve it a lot :-)
//
// So, when outputImageSize * outputImageSize > workgroupSize, then
// multiple workgroups will be created for each output plane
// the number of such workgroups is given by: `gPixelsPerThread`
// the id of our workgroup within such a set of workgroups is calculated
// as `pixel`
// effectiveLocalId is our local id if we had one enormous workgroup
// containing the whole output image plane
void kernel forward_4_by_n_outplane_smallercache( const int batchSize,
      global const float *images, global const float *filters, 
        #ifdef BIASED
            global const float*biases, 
        #endif
    global float *output,
    local float *_upstreamImage, local float *_filterPlane ) {
    #define globalId ( get_global_id(0) )

    #define localId ( get_local_id(0) )
    #define workgroupId ( get_group_id(0) )
//    const int workgroupSize = get_local_size(0);
    const int effectiveWorkgroupId = workgroupId / gPixelsPerThread;
    const int pixel = workgroupId % gPixelsPerThread;
    const int effectiveLocalId = localId + pixel * gWorkgroupSize;
    const int n = effectiveWorkgroupId / gNumFilters;
    const int outPlane = effectiveWorkgroupId % gNumFilters;

    const int outputRow = effectiveLocalId / gOutputImageSize;
    const int outputCol = effectiveLocalId % gOutputImageSize;

    float sum = 0;
    for( int upstreamPlane = 0; upstreamPlane < gInputPlanes; upstreamPlane++ ) {
        barrier(CLK_LOCAL_MEM_FENCE);
        copyLocal( _upstreamImage, images + ( n * gInputPlanes + upstreamPlane ) * gInputImageSizeSquared, gInputImageSizeSquared );
        copyLocal( _filterPlane, filters + ( outPlane * gInputPlanes + upstreamPlane ) * gFilterSizeSquared, gFilterSizeSquared );
        barrier(CLK_LOCAL_MEM_FENCE);

        if( effectiveLocalId < gOutputImageSizeSquared ) {
            for( int u = -gHalfFilterSize; u <= gHalfFilterSize - gEven; u++ ) {
                // trying to reduce register pressure...
                #if gPadZeros == 1
                    #define inputRow ( outputRow + u )
                #else
                    #define inputRow ( outputRow + u + gHalfFilterSize )
                #endif
                int inputimagerowoffset = inputRow * gInputImageSize;
                int filterrowoffset = (u+gHalfFilterSize) * gFilterSize + gHalfFilterSize;
                bool rowOk = inputRow >= 0 && inputRow < gInputImageSize;
                for( int v = -gHalfFilterSize; v <= gHalfFilterSize - gEven; v++ ) {
                    #if gPadZeros == 1
                        #define inputCol ( outputCol + v )
                    #else
                        #define inputCol ( outputCol + v + gHalfFilterSize )
                    #endif
                    bool process = rowOk && inputCol >= 0 && inputCol < gInputImageSize;
                    if( process ) {
                            sum += _upstreamImage[ inputimagerowoffset + inputCol] * _filterPlane[ filterrowoffset + v ];
                    }
                }
            }
        }
    }
    #ifdef BIASED
        sum += biases[outPlane];
    #endif
    // output are organized like [imageid][filterid][row][col]
    #define resultIndex ( ( n * gNumFilters + outPlane ) * gOutputImageSizeSquared + effectiveLocalId )
    if( effectiveLocalId < gOutputImageSizeSquared ) {
        output[resultIndex ] = sum;
    }
    // output[resultIndex ] = 123;
    //if( globalId == 0 ) output[0] += 0.000001f + _perPixelSums[0];
}
#endif

