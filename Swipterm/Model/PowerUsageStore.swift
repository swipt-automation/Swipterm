import Foundation
import GRDB
import Observation
import SwiptermKit

nonisolated enum PowerUsageRange: String, CaseIterable, Sendable {
    case day
    case tenDays
}

nonisolated struct PowerUsageBucket: Identifiable, Equatable, Sendable {
    let start: Date
    let end: Date
    let foregroundEnergyNanojoules: UInt64
    let backgroundEnergyNanojoules: UInt64

    var id: Date {
        start
    }

    var totalEnergyNanojoules: UInt64 {
        foregroundEnergyNanojoules &+ backgroundEnergyNanojoules
    }

    var foregroundMilliwattHours: Double {
        Double(foregroundEnergyNanojoules) / 3_600_000_000
    }

    var backgroundMilliwattHours: Double {
        Double(backgroundEnergyNanojoules) / 3_600_000_000
    }

    var totalMilliwattHours: Double {
        Double(totalEnergyNanojoules) / 3_600_000_000
    }
}

nonisolated struct ProcessPowerSummary: Identifiable, Equatable, Sendable {
    let process: String
    let energyNanojoules: UInt64
    let foregroundEnergyNanojoules: UInt64
    let backgroundEnergyNanojoules: UInt64
    let foregroundCPUMicroseconds: UInt64
    let backgroundCPUMicroseconds: UInt64
    let share: Double

    var id: String {
        process
    }
}

nonisolated struct PowerUsageSnapshot: Equatable, Sendable {
    let buckets: [PowerUsageBucket]
    let processes: [ProcessPowerSummary]
    let foregroundEnergyNanojoules: UInt64
    let backgroundEnergyNanojoules: UInt64

    var totalEnergyNanojoules: UInt64 {
        foregroundEnergyNanojoules &+ backgroundEnergyNanojoules
    }
}

@Observable
final class PowerUsageStore {
    private nonisolated struct Row: FetchableRecord {
        let bucket: Int64
        let isBackground: Bool
        let process: String
        let energyNanojoules: Int64
        let cpuMicroseconds: Int64

        init(row: GRDB.Row) {
            bucket = row["bucket"]
            isBackground = (row["isBackground"] as Int64) != 0
            process = row["process"]
            energyNanojoules = row["energyNanojoules"]
            cpuMicroseconds = row["cpuMicroseconds"]
        }
    }

    private nonisolated static let bucketGranularitySeconds: Int64 = 900
    private static let retentionSeconds: Int64 = 14 * 86400

    private(set) var revision: UInt64 = 0
    @ObservationIgnored private let database: DatabaseQueue

    init(database: DatabaseQueue) {
        self.database = database
    }

    func record(
        _ samples: [LinuxRuntime.ProcessEnergySample],
        isBackground: Bool,
        at date: Date = Date()
    ) {
        guard !samples.isEmpty else { return }
        let slot = Self.slotEpoch(for: date)
        let cutoff = slot - Self.retentionSeconds
        let bgFlag: Int64 = isBackground ? 1 : 0
        try! database.write { db in
            try db.execute(sql: "DELETE FROM power_usage WHERE bucket < ?", arguments: [cutoff])
            for sample in samples where sample.energyNanojoules > 0 || sample.cpuMicroseconds > 0 {
                let energy = Int64(clamping: sample.energyNanojoules)
                let cpu = Int64(clamping: sample.cpuMicroseconds)
                try db.execute(
                    sql: """
                    INSERT INTO power_usage (bucket, isBackground, process, energyNanojoules, cpuMicroseconds)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (bucket, isBackground, process) DO UPDATE SET
                        energyNanojoules = energyNanojoules + excluded.energyNanojoules,
                        cpuMicroseconds = cpuMicroseconds + excluded.cpuMicroseconds
                    """,
                    arguments: [slot, bgFlag, sample.name, energy, cpu]
                )
            }
        }
        revision &+= 1
    }

    func reset() {
        try! database.write { db in
            try db.execute(sql: "DELETE FROM power_usage")
        }
        revision &+= 1
    }

    func snapshot(
        range: PowerUsageRange,
        selectedBucket: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PowerUsageSnapshot {
        let windowStart: Int64
        let windowEnd: Int64
        var bucketRanges: [(start: Date, end: Date, startEpoch: Int64, endEpoch: Int64)] = []

        switch range {
        case .day:
            let currentHour = calendar.dateInterval(of: .hour, for: now)!.start
            let firstHour = calendar.date(byAdding: .hour, value: -23, to: currentHour)!
            let endHour = calendar.date(byAdding: .hour, value: 1, to: currentHour)!
            windowStart = Int64(firstHour.timeIntervalSince1970)
            windowEnd = Int64(endHour.timeIntervalSince1970)
            bucketRanges.reserveCapacity(24)
            for index in 0 ..< 24 {
                let hStart = calendar.date(byAdding: .hour, value: index, to: firstHour)!
                let hEnd = calendar.date(byAdding: .hour, value: 1, to: hStart)!
                bucketRanges.append((
                    hStart,
                    hEnd,
                    Int64(hStart.timeIntervalSince1970),
                    Int64(hEnd.timeIntervalSince1970)
                ))
            }
        case .tenDays:
            let todayStart = calendar.startOfDay(for: now)
            let firstDay = calendar.date(byAdding: .day, value: -9, to: todayStart)!
            let endDay = calendar.date(byAdding: .day, value: 1, to: todayStart)!
            windowStart = Int64(firstDay.timeIntervalSince1970)
            windowEnd = Int64(endDay.timeIntervalSince1970)
            bucketRanges.reserveCapacity(10)
            for index in 0 ..< 10 {
                let dStart = calendar.date(byAdding: .day, value: index, to: firstDay)!
                let dEnd = calendar.date(byAdding: .day, value: 1, to: dStart)!
                bucketRanges.append((
                    dStart,
                    dEnd,
                    Int64(dStart.timeIntervalSince1970),
                    Int64(dEnd.timeIntervalSince1970)
                ))
            }
        }

        let rows = try! database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT bucket, isBackground, process, energyNanojoules, cpuMicroseconds
                FROM power_usage
                WHERE bucket >= ? AND bucket < ?
                """,
                arguments: [windowStart, windowEnd]
            )
        }

        let buckets = bucketRanges.map { span in
            var fg: UInt64 = 0
            var bg: UInt64 = 0
            for row in rows where row.bucket >= span.startEpoch && row.bucket < span.endEpoch && row.energyNanojoules > 0 {
                if row.isBackground {
                    bg &+= UInt64(row.energyNanojoules)
                } else {
                    fg &+= UInt64(row.energyNanojoules)
                }
            }
            return PowerUsageBucket(
                start: span.start,
                end: span.end,
                foregroundEnergyNanojoules: fg,
                backgroundEnergyNanojoules: bg
            )
        }

        let activeFilter = selectedBucket.flatMap { selected in
            bucketRanges.first { $0.start == selected }
        }
        let filterStart = activeFilter?.startEpoch ?? windowStart
        let filterEnd = activeFilter?.endEpoch ?? windowEnd

        struct Accum {
            var fgEnergy: UInt64 = 0
            var bgEnergy: UInt64 = 0
            var fgCPU: UInt64 = 0
            var bgCPU: UInt64 = 0

            var totalEnergy: UInt64 {
                fgEnergy &+ bgEnergy
            }

            var totalCPU: UInt64 {
                fgCPU &+ bgCPU
            }
        }

        var byProcess: [String: Accum] = [:]
        var totalFgEnergy: UInt64 = 0
        var totalBgEnergy: UInt64 = 0
        var totalCPU: UInt64 = 0

        for row in rows where row.bucket >= filterStart && row.bucket < filterEnd {
            let e = row.energyNanojoules > 0 ? UInt64(row.energyNanojoules) : 0
            let c = row.cpuMicroseconds > 0 ? UInt64(row.cpuMicroseconds) : 0
            guard e > 0 || c > 0 else { continue }

            var acc = byProcess[row.process] ?? Accum()
            if row.isBackground {
                acc.bgEnergy &+= e
                acc.bgCPU &+= c
                totalBgEnergy &+= e
            } else {
                acc.fgEnergy &+= e
                acc.fgCPU &+= c
                totalFgEnergy &+= e
            }
            byProcess[row.process] = acc
            totalCPU &+= c
        }

        let totalEnergy = totalFgEnergy &+ totalBgEnergy
        let sorted = byProcess.sorted { lhs, rhs in
            if lhs.value.totalEnergy != rhs.value.totalEnergy {
                return lhs.value.totalEnergy > rhs.value.totalEnergy
            }
            if lhs.value.totalCPU != rhs.value.totalCPU {
                return lhs.value.totalCPU > rhs.value.totalCPU
            }
            return lhs.key < rhs.key
        }

        let processes = sorted.map { entry in
            let share: Double = if totalEnergy > 0 {
                Double(entry.value.totalEnergy) / Double(totalEnergy)
            } else if totalCPU > 0 {
                Double(entry.value.totalCPU) / Double(totalCPU)
            } else {
                0
            }
            return ProcessPowerSummary(
                process: entry.key,
                energyNanojoules: entry.value.totalEnergy,
                foregroundEnergyNanojoules: entry.value.fgEnergy,
                backgroundEnergyNanojoules: entry.value.bgEnergy,
                foregroundCPUMicroseconds: entry.value.fgCPU,
                backgroundCPUMicroseconds: entry.value.bgCPU,
                share: share
            )
        }

        return PowerUsageSnapshot(
            buckets: buckets,
            processes: processes,
            foregroundEnergyNanojoules: totalFgEnergy,
            backgroundEnergyNanojoules: totalBgEnergy
        )
    }

    private nonisolated static func slotEpoch(for date: Date) -> Int64 {
        let seconds = Int64(date.timeIntervalSince1970)
        let g = bucketGranularitySeconds
        return seconds >= 0 ? (seconds / g) * g : ((seconds - (g - 1)) / g) * g
    }
}
