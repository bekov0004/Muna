import AppKit
import Combine
import Foundation
import SwiftUI

/// Downloads: watches the Downloads folder and shows files arriving (partial files that grow) and
/// the last ones finished.
final class DownloadsModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var name: String
        var size: Int64
        /// Bytes per second (in progress only).
        var speed: Double
        var at: Date
    }

    static let partialExtensions: Set<String> = ["part", "crdownload", "download", "opdownload", "partial"]
    static let recentCount = 8

    @Published private(set) var active: [Item] = []
    @Published private(set) var recent: [Item] = []

    /// A download finished: the final file.
    var onFinished: (URL) -> Void = { _ in }

    let folder: URL
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    /// Files present at the last scan: path -> size.
    private var known: [String: Int64] = [:]
    private var started = false
    /// Reading the folder can wait for macOS to ask the user (Downloads is a protected folder):
    /// it never happens on the main thread, or the whole app would stand still meanwhile.
    private let work = DispatchQueue(label: "dev.muna.downloads", qos: .utility)
    private var scanning = false
    private var scanAgain = false

    init() {
        folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    deinit {
        timer?.invalidate()
        source?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        let folder = self.folder
        work.async { [weak self] in
            let first = DownloadsModel.sizes(in: folder)
            let descriptor = open(folder.path, O_EVTONLY)
            DispatchQueue.main.async {
                guard let self else {
                    if descriptor >= 0 { close(descriptor) }
                    return
                }
                self.known = first
                guard descriptor >= 0 else { return }
                let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                        eventMask: [.write, .rename, .delete, .extend],
                                                                        queue: .main)
                watcher.setEventHandler { [weak self] in self?.scan() }
                watcher.setCancelHandler { close(descriptor) }
                watcher.resume()
                self.source = watcher
                self.scan()
            }
        }
    }

    static func isPartial(_ url: URL) -> Bool {
        partialExtensions.contains(url.pathExtension.lowercased())
    }

    /// The size of a file, or of a bundle (Safari's .download is a folder).
    private static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isFolder) else { return 0 }
        if !isFolder.boolValue {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let walker = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    private static func sizes(in folder: URL) -> [String: Int64] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var result: [String: Int64] = [:]
        for name in names where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            result[url.path] = size(of: url)
        }
        return result
    }

    /// Reads the folder off the main thread, then compares it with the last scan.
    private func scan() {
        if scanning {
            scanAgain = true
            return
        }
        scanning = true
        let folder = self.folder
        work.async { [weak self] in
            let current = DownloadsModel.sizes(in: folder)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.compare(current)
                if self.scanAgain {
                    self.scanAgain = false
                    self.scan()
                }
            }
        }
    }

    private func compare(_ current: [String: Int64]) {
        let now = Date()
        var nextActive: [Item] = []
        for (path, size) in current {
            let url = URL(fileURLWithPath: path)
            guard DownloadsModel.isPartial(url) else { continue }
            let before = active.first { $0.url.path == path }
            let lastSize = before?.size ?? known[path] ?? size
            let seconds = before.map { now.timeIntervalSince($0.at) } ?? 0
            let speed = seconds > 0.2 ? Double(max(0, size - lastSize)) / seconds : (before?.speed ?? 0)
            nextActive.append(Item(url: url, name: url.deletingPathExtension().lastPathComponent,
                                   size: size, speed: speed, at: now))
        }
        // New plain files: a partial one renamed to its final name, or a file saved at once.
        for (path, size) in current where known[path] == nil {
            let url = URL(fileURLWithPath: path)
            if DownloadsModel.isPartial(url) { continue }
            finish(Item(url: url, name: url.lastPathComponent, size: size, speed: 0, at: now))
        }
        known = current
        active = nextActive.sorted { $0.name < $1.name }
        updateTimer()
    }

    private func finish(_ item: Item) {
        recent = Array(([item] + recent.filter { $0.url.path != item.url.path }).prefix(DownloadsModel.recentCount))
        onFinished(item.url)
    }

    /// Partial files can grow without folder events: look every second while there are some.
    private func updateTimer() {
        if !active.isEmpty && timer == nil {
            let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.scan() }
            RunLoop.main.add(tick, forMode: .common)
            timer = tick
        } else if active.isEmpty {
            timer?.invalidate()
            timer = nil
        }
        // Drop finished files that are gone.
        let manager = FileManager.default
        let kept = recent.filter { manager.fileExists(atPath: $0.url.path) }
        if kept.count != recent.count { recent = kept }
    }

    func openFile(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openFolder() {
        NSWorkspace.shared.open(folder)
    }
}

struct DownloadsPage: View {
    @EnvironmentObject var downloads: DownloadsModel

    var body: some View {
        QuickBlock {
            Caption("Downloads") {
                Pill(label: "Folder") { downloads.openFolder() }
            }
            if downloads.active.isEmpty && downloads.recent.isEmpty {
                Text("Nothing downloaded since Muna started.")
                    .font(.system(size: 11))
                    .foregroundColor(MunaColor.secondary)
            }
            ForEach(downloads.active) { item in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16))
                        .foregroundColor(MunaColor.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.system(size: 12)).foregroundColor(MunaColor.text).lineLimit(1)
                        Text(item.speed > 0 ? "\(sizeText(item.size)) · \(sizeText(Int64(item.speed)))/s" : sizeText(item.size))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(MunaColor.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { downloads.reveal(item) }
            }
            ForEach(downloads.recent) { item in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.system(size: 12)).foregroundColor(MunaColor.text).lineLimit(1)
                        Text("\(sizeText(item.size)) · \(item.at.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(MunaColor.secondary)
                    }
                    Spacer(minLength: 4)
                    IconButton(symbol: "magnifyingglass") { downloads.reveal(item) }
                }
                .contentShape(Rectangle())
                .onTapGesture { downloads.openFile(item) }
            }
        }
    }
}
