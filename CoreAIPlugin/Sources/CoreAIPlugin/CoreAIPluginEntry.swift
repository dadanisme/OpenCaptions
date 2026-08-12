//
//  CoreAIPluginEntry.swift
//  CoreAIPlugin
//
//  The single C-ABI-visible symbol CoreAIPluginLoader dlsym's by name — the
//  Swift side of the dlopen boundary has no stable ABI to link against
//  otherwise, across two independently-compiled binaries.
//

import Foundation

@_cdecl("makeCoreAITranscriptionPlugin")
public func makeCoreAITranscriptionPlugin() -> UnsafeMutableRawPointer {
    let instance = CoreAIParakeetPlugin()
    return UnsafeMutableRawPointer(Unmanaged.passRetained(instance).toOpaque())
}
