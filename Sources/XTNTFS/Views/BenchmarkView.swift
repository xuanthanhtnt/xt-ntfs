import SwiftUI
import XTShared

struct BenchmarkView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.benchmarkSize) private var sizeMB = 1024
    @State private var target: String = ""
    @State private var running = false
    @State private var progress: Double = 0
    @State private var phase = ""
    @State private var runner: BenchmarkRunner?
    @State private var lastResult: BenchmarkResult?

    var candidates: [Volume] {
        model.volumes.filter { $0.isMounted && !$0.readOnly && !$0.isRootVolume }
    }

    var body: some View {
        Card(title: NSLocalizedString("Benchmark", comment: ""), systemImage: "stopwatch.fill", tint: Theme.accent) {
            Text(NSLocalizedString("Measures sequential write and read speed (cache bypassed) and small-file throughput on a mounted volume. To compare with another NTFS driver, disable the XT NTFS driver, reconnect the disk so the other driver mounts it, and run the benchmark again.", comment: ""))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker(NSLocalizedString("Volume", comment: ""), selection: $target) {
                    if candidates.isEmpty {
                        Text(NSLocalizedString("No writable volume", comment: "")).tag("")
                    }
                    ForEach(candidates) { v in
                        Text("\(v.name) — \(v.driverName ?? v.fileSystemName)").tag(v.bsdName)
                    }
                }
                .frame(maxWidth: 340)
                Picker(NSLocalizedString("Size", comment: ""), selection: $sizeMB) {
                    Text("256 MB").tag(256)
                    Text("1 GB").tag(1024)
                    Text("4 GB").tag(4096)
                }
                .frame(width: 150)
                if running {
                    Button(NSLocalizedString("Stop", comment: "")) { runner?.cancel() }
                } else {
                    Button(NSLocalizedString("Run Benchmark", comment: "")) { start() }
                        .disabled(candidates.first { $0.bsdName == target } == nil)
                }
            }
            if running {
                ProgressView(value: progress) { Text(phase).font(.system(size: 11)) }
            }
            if let r = lastResult {
                HStack(spacing: 30) {
                    metric(NSLocalizedString("Write", comment: ""), Format.rate(r.writeMBps), Theme.erasePink)
                    metric(NSLocalizedString("Read", comment: ""), Format.rate(r.readMBps), Theme.mountBlue)
                    metric(NSLocalizedString("Small files", comment: ""),
                           String(format: NSLocalizedString("%.0f files/s", comment: ""), r.smallFilesPerSecond), Theme.verifyGreen)
                }
                .padding(.vertical, 4)
            }
            if !model.benchmarkHistory.isEmpty {
                history
            }
        }
        .onAppear { pickDefault() }
        .onChange(of: candidates.map(\.bsdName)) { _ in pickDefault() }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(color)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(NSLocalizedString("History", comment: "")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(NSLocalizedString("Clear", comment: "")) { model.clearBenchmarks() }
                    .buttonStyle(.link)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text(NSLocalizedString("Date", comment: ""))
                    Text(NSLocalizedString("Volume", comment: ""))
                    Text(NSLocalizedString("Driver", comment: ""))
                    Text(NSLocalizedString("Size", comment: ""))
                    Text(NSLocalizedString("Write", comment: ""))
                    Text(NSLocalizedString("Read", comment: ""))
                    Text(NSLocalizedString("Small files", comment: ""))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                ForEach(model.benchmarkHistory.prefix(12)) { r in
                    GridRow {
                        Text(r.date, format: .dateTime.day().month().hour().minute())
                        Text(r.volumeName).lineLimit(1)
                        Text(r.driver).lineLimit(1)
                        Text(r.sizeMB >= 1024 ? "\(r.sizeMB / 1024) GB" : "\(r.sizeMB) MB")
                        Text(Format.rate(r.writeMBps))
                        Text(Format.rate(r.readMBps))
                        Text(String(format: "%.0f/s", r.smallFilesPerSecond))
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                }
            }
        }
        .padding(.top, 6)
    }

    private func pickDefault() {
        if candidates.contains(where: { $0.bsdName == target }) { return }
        target = (candidates.first { $0.isNTFS } ?? candidates.first)?.bsdName ?? ""
    }

    private func start() {
        guard let v = candidates.first(where: { $0.bsdName == target }) else { return }
        let r = BenchmarkRunner()
        runner = r
        running = true
        progress = 0
        phase = ""
        let size = sizeMB
        Task {
            let outcome: Result<BenchmarkResult, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let res = try r.run(volume: v, sizeMB: size) { p, text in
                        Task { @MainActor in
                            progress = p
                            phase = text
                        }
                    }
                    return .success(res)
                } catch {
                    return .failure(error)
                }
            }.value
            running = false
            runner = nil
            switch outcome {
            case .success(let res):
                lastResult = res
                model.addBenchmark(res)
            case .failure(let err):
                if !(err is CancellationError) {
                    model.alert = AlertItem(title: NSLocalizedString("Benchmark failed", comment: ""),
                                            message: err.localizedDescription)
                }
            }
        }
    }
}
