import Foundation
import XCTest

/// Opt-in measurements; ordinary test runs skip expensive speed fixtures.
enum SpeedBenchmark {
    static func requireEnabled() throws {
        guard ProcessInfo.processInfo.environment["LOUPPE_SPEED_TESTS"] == "1" else {
            throw XCTSkip("Run Tests/run_speed_tests.sh for optimized statistical speed tests")
        }
        let environment = ProcessInfo.processInfo.environment
        if let requested = environment["LOUPPE_SPEED_SIZES"] {
            let parts = requested.split(separator: ",", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ Int($0).map { (100...100_000).contains($0) } == true }) else {
                throw NSError(domain: "LouppeSpeed", code: 1, userInfo: [NSLocalizedDescriptionKey: "LOUPPE_SPEED_SIZES must be comma-separated integers from 100 through 100000"])
            }
        }
        if let requested = environment["LOUPPE_SPEED_REPETITIONS"],
           Int(requested).map({ (3...30).contains($0) }) != true {
            throw NSError(domain: "LouppeSpeed", code: 2, userInfo: [NSLocalizedDescriptionKey: "LOUPPE_SPEED_REPETITIONS must be an integer from 3 through 30"])
        }
    }

    static var sizes: [Int] {
        let raw = ProcessInfo.processInfo.environment["LOUPPE_SPEED_SIZES"] ?? "1000,10000,100000"
        let values = raw.split(separator: ",").compactMap { Int($0) }
        return Array(Set(values.filter { (100...100_000).contains($0) })).sorted()
    }

    static var repetitions: Int {
        min(30, max(3, Int(ProcessInfo.processInfo.environment["LOUPPE_SPEED_REPETITIONS"] ?? "7") ?? 7))
    }

    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
}

@MainActor
final class SpeedReport {
    struct Row: Codable {
        let name: String
        let count: Int
        let samplesMS: [Double]
        let medianMS: Double
        let p95MS: Double
        let minMS: Double
        let maxMS: Double
    }

    struct Document: Codable {
        let schemaVersion: Int
        let suite: String
        let generatedAt: Date
        let os: String
        let processors: Int
        let physicalMemoryBytes: UInt64
        let warmups: Int
        let repetitions: Int
        let rows: [Row]
    }

    let suite: String
    private(set) var rows: [Row] = []

    init(suite: String) { self.suite = suite }

    /// Setup/fixture creation belongs outside this closure. Consume and validate
    /// results after measurement. A warmup is explicit, never called cold I/O.
    func measure(name: String, count: Int, prepare: () throws -> Void = {}, operation: () throws -> Void) throws {
        try prepare()
        try operation()
        var samples: [Double] = []
        for _ in 0..<SpeedBenchmark.repetitions {
            try prepare()
            let start = ContinuousClock.now
            try operation()
            samples.append(SpeedBenchmark.milliseconds(start))
        }
        record(name: name, count: count, samples: samples)
    }

    func measureAsync(name: String, count: Int, operation: () async throws -> Void) async throws {
        try await operation()
        var samples: [Double] = []
        for _ in 0..<SpeedBenchmark.repetitions {
            let start = ContinuousClock.now
            try await operation()
            samples.append(SpeedBenchmark.milliseconds(start))
        }
        record(name: name, count: count, samples: samples)
    }

    /// Latencies observed within a larger async operation. Callers remove the
    /// first (warmup) entry explicitly; these use the same statistical format.
    func recordSamples(name: String, count: Int, samplesMS: [Double]) throws {
        guard samplesMS.count == SpeedBenchmark.repetitions,
              samplesMS.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw NSError(domain: "LouppeSpeed", code: 3, userInfo: [NSLocalizedDescriptionKey: "Latency diagnostics must contain one finite value per measured repetition"])
        }
        record(name: name, count: count, samples: samplesMS)
    }

    private func record(name: String, count: Int, samples: [Double]) {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        let row = Row(name: name, count: count, samplesMS: samples,
                      medianMS: median,
                      p95MS: sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
                      minMS: sorted[0], maxMS: sorted[sorted.count - 1])
        rows.append(row)
        print(String(format: "SPEED %@ n=%d median=%.3fms p95=%.3fms", name, count, row.medianMS, row.p95MS))
    }

    func finish() throws {
        let output = ProcessInfo.processInfo.environment["LOUPPE_SPEED_OUTPUT"]
            ?? "/private/tmp/louppe-speed-results"
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let process = ProcessInfo.processInfo
        let document = Document(schemaVersion: 1, suite: suite, generatedAt: Date(),
                                os: process.operatingSystemVersionString,
                                processors: process.processorCount,
                                physicalMemoryBytes: process.physicalMemory,
                                warmups: 1, repetitions: SpeedBenchmark.repetitions, rows: rows)
        try encoder.encode(document).write(to: directory.appendingPathComponent("\(suite).json"), options: .atomic)
    }
}
