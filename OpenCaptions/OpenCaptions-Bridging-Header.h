//
//  OpenCaptions-Bridging-Header.h
//  OpenCaptions
//
//  Objective-C headers exposed to Swift. Currently just the software echo
//  canceller (OpenCaptionsAEC), an Objective-C++ bridge over the vendored SpeexDSP.
//  Wired via the SWIFT_OBJC_BRIDGING_HEADER build setting on the OpenCaptions target.
//

#import "AEC/OpenCaptionsAEC.h"
