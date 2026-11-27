import Charts
import SwiftUI

struct PowerUsageView: View {
    private struct ChartEntry: Identifiable {
        let id: String
        let start: Date
        let end: Date
        let category: String
        let value: Double
    }

    @Environment(LinuxSystem.self) private var system
    @Environment(PowerUsageStore.self) private var powerUsage

    @State private var range: PowerUsageRange = .day
    @State private var selectedBucketStart: Date?

    var body: some View {
        let _ = powerUsage.revision
        let snapshot = powerUsage.snapshot(
            range: range,
            selectedBucket: selectedBucketStart
        )
        let usesWattHours = (snapshot.buckets.map(\.totalMilliwattHours).max() ?? 0) >= 1000
        let fgLabel = String(localized: "Foreground")
        let bgLabel = String(localized: "Background")
        let chartEntries = Self.makeChartEntries(
            buckets: snapshot.buckets,
            usesWattHours: usesWattHours,
            fgLabel: fgLabel,
            bgLabel: bgLabel
        )

        Form {
            Section {
                Picker("Range", selection: $range) {
                    Text("Last 24 Hours").tag(PowerUsageRange.day)
                    Text("Last 10 Days").tag(PowerUsageRange.tenDays)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let selectedBucketStart,
                           let bucket = snapshot.buckets.first(where: { $0.start == selectedBucketStart })
                        {
                            Text(Self.bucketLabel(for: bucket, range: range))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Total Energy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(verbatim: Self.formatEnergy(snapshot.totalEnergyNanojoules))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()

                        let fgText = String(localized: "Foreground \(Self.formatEnergy(snapshot.foregroundEnergyNanojoules))")
                        let bgText = String(localized: "Background \(Self.formatEnergy(snapshot.backgroundEnergyNanojoules))")
                        Text(verbatim: "\(fgText) · \(bgText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Chart(chartEntries) { entry in
                        let isSelected = selectedBucketStart == nil || selectedBucketStart == entry.start
                        BarMark(
                            x: .value("Time", entry.start ..< entry.end),
                            y: .value("Energy", entry.value)
                        )
                        .foregroundStyle(by: .value("Activity", entry.category))
                        .opacity(isSelected ? 1 : 0.3)
                    }
                    .chartForegroundStyleScale([
                        fgLabel: Color.accentColor,
                        bgLabel: Color.indigo,
                    ])
                    .chartLegend(.visible)
                    .frame(height: 180)
                    .chartYAxis {
                        AxisMarks(position: .trailing) { axisValue in
                            AxisGridLine()
                            AxisValueLabel {
                                if let v = axisValue.as(Double.self) {
                                    let unit = usesWattHours ? "Wh" : "mWh"
                                    Text(verbatim: "\(v.formatted(.number.precision(.fractionLength(0 ... 1)))) \(unit)")
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        switch range {
                        case .day:
                            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                                AxisGridLine()
                                AxisTick()
                                AxisValueLabel(format: .dateTime.hour())
                            }
                        case .tenDays:
                            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                                AxisGridLine()
                                AxisTick()
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            }
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let x = location.x - geometry[plotFrame].origin.x
                                    guard x >= 0, x <= geometry[plotFrame].width,
                                          let tappedDate: Date = proxy.value(atX: x)
                                    else {
                                        selectedBucketStart = nil
                                        return
                                    }
                                    if let hit = snapshot.buckets.first(where: { tappedDate >= $0.start && tappedDate < $0.end }) {
                                        selectedBucketStart = selectedBucketStart == hit.start ? nil : hit.start
                                    } else {
                                        selectedBucketStart = nil
                                    }
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Processes") {
                if snapshot.processes.isEmpty {
                    Text("No Power Usage Recorded")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.processes) { item in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: item.process)
                                    .lineLimit(1)
                                Text(verbatim: Self.processSubtitle(for: item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                            Text(verbatim: Self.formatShare(item.share))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle("Power Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        selectedBucketStart = nil
                        Task {
                            await system.resetPowerUsage()
                        }
                    } label: {
                        Label("Reset Statistics", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Label("Others", systemImage: "ellipsis")
                }
            }
        }
        .onChange(of: range) { _, _ in
            selectedBucketStart = nil
        }
        .task {
            await system.flushPowerUsage()
        }
    }

    private static func makeChartEntries(
        buckets: [PowerUsageBucket],
        usesWattHours: Bool,
        fgLabel: String,
        bgLabel: String
    ) -> [ChartEntry] {
        let scale = usesWattHours ? 1000.0 : 1.0
        var entries: [ChartEntry] = []
        entries.reserveCapacity(buckets.count * 2)
        for bucket in buckets {
            let stamp = Int64(bucket.start.timeIntervalSince1970)
            entries.append(ChartEntry(
                id: "\(stamp)-fg",
                start: bucket.start,
                end: bucket.end,
                category: fgLabel,
                value: bucket.foregroundMilliwattHours / scale
            ))
            entries.append(ChartEntry(
                id: "\(stamp)-bg",
                start: bucket.start,
                end: bucket.end,
                category: bgLabel,
                value: bucket.backgroundMilliwattHours / scale
            ))
        }
        return entries
    }

    private static func processSubtitle(for item: ProcessPowerSummary) -> String {
        var parts = [formatEnergy(item.energyNanojoules)]
        if item.foregroundCPUMicroseconds > 0 || item.foregroundEnergyNanojoules > 0 {
            parts.append(String(localized: "Foreground \(formatCPUDuration(item.foregroundCPUMicroseconds))"))
        }
        if item.backgroundCPUMicroseconds > 0 || item.backgroundEnergyNanojoules > 0 {
            parts.append(String(localized: "Background \(formatCPUDuration(item.backgroundCPUMicroseconds))"))
        }
        return parts.joined(separator: " · ")
    }

    private static func bucketLabel(for bucket: PowerUsageBucket, range: PowerUsageRange) -> String {
        switch range {
        case .day:
            let startText = bucket.start.formatted(.dateTime.hour().minute())
            let endText = bucket.end.formatted(.dateTime.hour().minute())
            return "\(startText)–\(endText)"
        case .tenDays:
            return bucket.start.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private static func formatEnergy(_ nanojoules: UInt64) -> String {
        let mWh = Double(nanojoules) / 3_600_000_000
        if mWh >= 1000 {
            let wh = mWh / 1000
            return "\(wh.formatted(.number.precision(.fractionLength(2)))) Wh"
        }
        if mWh >= 10 {
            return "\(mWh.formatted(.number.precision(.fractionLength(1)))) mWh"
        }
        if mWh >= 0.01 {
            return "\(mWh.formatted(.number.precision(.fractionLength(2)))) mWh"
        }
        if nanojoules > 0 {
            return "< 0.01 mWh"
        }
        return "0 mWh"
    }

    private static func formatCPUDuration(_ microseconds: UInt64) -> String {
        if microseconds < 1_000_000 {
            let ms = Double(microseconds) / 1000
            return "\(ms.formatted(.number.precision(.fractionLength(0)))) ms"
        }
        return Duration.microseconds(Int64(clamping: microseconds)).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
    }

    private static func formatShare(_ share: Double) -> String {
        if share > 0, share < 0.01 {
            return "<1%"
        }
        return share.formatted(.percent.precision(.fractionLength(0)))
    }
}
