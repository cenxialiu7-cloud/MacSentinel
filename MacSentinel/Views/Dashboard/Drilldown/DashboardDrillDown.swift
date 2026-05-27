//
//  DashboardDrillDown.swift
//  MacSentinel
//
//  Type used to drive `.sheet(item:)` for Dashboard card drill-downs.
//  Each case maps to a detail view shown when the corresponding metric card
//  is tapped.
//

import Foundation

enum DashboardDrillDown: Identifiable, Hashable {
    case cpu
    case memory
    case disk
    case network
    case battery
    case thermal
    case gpu

    var id: String { String(describing: self) }
}
