//
//  DrillDownContainer.swift
//  MacSentinel
//
//  Dispatches a DashboardDrillDown case to the matching detail view.
//  Wrapped in a NavigationStack + close button so each drill-down feels
//  like its own focused workspace.
//

import SwiftUI

struct DrillDownContainer: View {
    let item: DashboardDrillDown
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch item {
                case .cpu:     CPUDetailView()
                case .memory:  MemoryDetailView()
                case .network: NetworkDetailView()
                case .battery: BatteryDetailView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
