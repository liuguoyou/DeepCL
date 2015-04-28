// Copyright Hugh Perkins 2014,2015 hughperkins at gmail
//
// This Source Code Form is subject to the terms of the Mozilla Public License, 
// v. 2.0. If a copy of the MPL was not distributed with this file, You can 
// obtain one at http://mozilla.org/MPL/2.0/.

#include <iostream>
#include <algorithm>
#include <stdexcept>

#include "PropagateAuto.h"
#include "stringhelper.h"
#include "PropagateCpu.h"
#include "Propagate1.h"
#include "Propagate2.h"
#include "Propagate3.h"
#include "Propagate4.h"
#include "PropagateFc.h"
#include "PropagateByInputPlane.h"
#include "PropagateExperimental.h"
#include "StatefulTimer.h"
#include "Timer.h"

using namespace std;

#undef STATIC
#define STATIC 

#undef VIRTUAL
#define VIRTUAL 

PropagateAuto::PropagateAuto( OpenCLHelper *cl, LayerDimensions dim ) :
//        dim( layerDimensions ),
//        cl( cl ),
//        fn( fn ),
        Propagate( cl, dim ),
        milliseconds( 0 ),
        valid( 0 ),
        chosenIndex( -1 ),
        instances( 0 )
         {
    num = Propagate::getNumImplementations();
    milliseconds = new int[ num];
    valid = new bool[ num ];
    instances = new Propagate *[ num ];
    for( int i = 0; i < num; i++ ) {
        instances[i] = 0;
        valid[i] = false;
        milliseconds[i] = -1;
    }
    nextIndex = 0;
}
VIRTUAL PropagateAuto::~PropagateAuto() {
    for( int i = 0; i < num; i++ ) {
        if( instances[i] != 0 ) {
            delete instances[i];
        }
    }
}
VIRTUAL void PropagateAuto::forward( int batchSize, CLWrapper *dataWrapper, CLWrapper *weightsWrapper, 
        CLWrapper *biasWeightsWrapper, CLWrapper *outputWrapper ) {
//    Propagate *instance = 0;
//    cout << "PropagateAuto::forward" << endl;
    while( chosenIndex == -1 && nextIndex < num ) {
        int thisIndex = nextIndex;
        nextIndex++;
        if( Propagate::plausiblyOptimal( thisIndex, batchSize, dim ) ) {
            Propagate *candidate = 0;
            try {
                candidate = Propagate::instanceSpecific( thisIndex, cl, dim );
                instances[thisIndex] = candidate;
                valid[thisIndex] = true;
            } catch( runtime_error &e ) {
                cout << StatefulTimer::instance()->prefix << "PropagateAuto: instance " << thisIndex << ": this instance cant be used: " << e.what() << endl;
                valid[thisIndex] = false;
            }
            if( valid[thisIndex] ) {
                Timer timer;
                try {
                    candidate->forward( batchSize, dataWrapper, weightsWrapper, biasWeightsWrapper, outputWrapper );
                    milliseconds[thisIndex] = (int)timer.lap();
//                    cout << StatefulTimer::instance()->prefix << "PropagateAuto: instance " << thisIndex << " " << milliseconds[thisIndex] << "ms" << endl;
                    return;
                } catch( runtime_error &e ) {
                    cout << StatefulTimer::instance()->prefix << "PropagateAuto: instance " << thisIndex << " this instance cant be used: " << e.what() << endl;
                    valid[thisIndex] = false;
                    delete instances[thisIndex];
                    instances[thisIndex] = 0;
                }
            }
        }
    }
    if( chosenIndex == -1 ) {
        cout << StatefulTimer::instance()->prefix + "PropagateAuto::forward choosing best instance:" << endl;
        int bestIndex = -1;
        int bestTime = 0;
        for( int i = 0; i < num; i++ ) {
            if( !valid[i] ) {
                cout << "   instance " << i << ": cannot be used" << endl;
                continue;
            }
            cout << "   instance " << i << ": " << milliseconds[i] << "ms" << endl;
            if( bestIndex == -1 ) {
                bestIndex = i;
                bestTime = milliseconds[i];
                continue;
            }
            if( milliseconds[i] < bestTime ) {
                bestTime = milliseconds[i];
                bestIndex = i;
            }
        }
        if( bestIndex != -1 ) {
            cout << "   selected: instance " << bestIndex << endl;
            this->chosenIndex = bestIndex;
        } else {
            throw runtime_error(StatefulTimer::instance()->prefix + "No valid forward implementations found" );
        }
    }
//    cout << "PropagateAuto::forward using instance index: " << chosenIndex << endl;
    instances[chosenIndex]->forward( batchSize, dataWrapper, weightsWrapper, biasWeightsWrapper, outputWrapper );
}

