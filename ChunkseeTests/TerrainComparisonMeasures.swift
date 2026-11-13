import Darwin
import Foundation
import Testing

/// These are independent completed-operation clocks, never sums of nested draw intervals.
nonisolated enum TerrainComparisonMeasures {
    struct Interval: Codable, Sendable {
        let wallSeconds: Double
        let processCPUSeconds: Double
    }

    struct Stamp {
        let wall = DispatchTime.now().uptimeNanoseconds
        let cpu = Self.cpuSeconds()

        private static func cpuSeconds() -> Double {
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }

        func until(_ end: Self) -> Interval {
            Interval(wallSeconds: Double(end.wall - wall) / 1e9, processCPUSeconds: end.cpu - cpu)
        }
    }

    /// Read once after the whole workload and input/output verification. The high-water
    /// mark includes evidence capture and cannot be attributed to an individual case.
    static func processResources() throws -> [String: Any] {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0 && usage.ru_maxrss > 0)
        return ["processID": ProcessInfo.processInfo.processIdentifier,
                "peakRSSBytes": Int64(usage.ru_maxrss),
                "source": "getrusage(RUSAGE_SELF).ru_maxrss",
                "scope": "Host startup through the completed workload, evidence and input/output checks; final resource-record writing and test-framework teardown excluded"]
    }
}
