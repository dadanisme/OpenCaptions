//
//  CoreAIPluginEntry.swift
//  CoreAIPlugin
//
//  The C-ABI-visible symbols CoreAIPluginLoader dlsym's by name — the Swift
//  side of the dlopen boundary has no stable ABI to link against otherwise,
//  across two independently-compiled binaries. One factory per plugin
//  protocol: Parakeet (batch-only) and Nemotron (streaming, issue #55).
//

import Foundation

@_cdecl("makeCoreAITranscriptionPlugin")
public func makeCoreAITranscriptionPlugin() -> UnsafeMutableRawPointer {
    let instance = CoreAIParakeetPlugin()
    return UnsafeMutableRawPointer(Unmanaged.passRetained(instance).toOpaque())
}

@_cdecl("makeCoreAINemotronTranscriptionPlugin")
public func makeCoreAINemotronTranscriptionPlugin() -> UnsafeMutableRawPointer {
    let instance = CoreAINemotronPlugin()
    return UnsafeMutableRawPointer(Unmanaged.passRetained(instance).toOpaque())
}
