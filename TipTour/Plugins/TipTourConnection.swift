//
//  TipTourConnection.swift
//  TipTour
//
//  Tiny connection model for plugin-like integrations. Keep this small:
//  TipTour uses explicit built-in connections today, not dynamic plugin
//  loading or a marketplace.
//

import Foundation

enum TipTourConnectionKind: String, Codable, Hashable {
    case actionDriver
    case orchestrator
    case perception
    case harness
    case voiceHarness
}

struct TipTourConnection: Identifiable, Codable, Hashable {
    let id: String
    let displayName: String
    let kind: TipTourConnectionKind
    let description: String
    var isEnabled: Bool
}
