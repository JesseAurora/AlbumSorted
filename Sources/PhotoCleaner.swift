import SwiftUI
import Photos
import PhotosUI
import AVKit

// MARK: - App

@main
struct PhotoCleanerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Basic types

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case videos = "Videos"
    case screenshots = "Screenshots"
    case photos = "Photos"
    case live = "Live"
    case burst = "Bursts"
    case big = "50 MB+"
    case blurry = "Blurry"
    case duplicates = "Duplicates"
    var id: String { rawValue }
}

enum SortKey: String, CaseIterable, Identifiable {
    case size = "Size"
    case date = "Date"
    var id: String { rawValue }
}

/// Cached per-asset record (stored on disk so the app doesn't rescan on every launch).
struct Rec: Codable {
    var local: Int64      // bytes actually stored on this iPhone
    var total: Int64      // bytes including parts that live only in iCloud
    var mod: Double       // modification date, to detect edits
    var blur: Float?      // Laplacian variance (low = blurry)
    var hash: String?     // dHash hex; "-" = could not analyze
    var size: Int64 { SizeMode.countICloud ? total : local }
}

/// Global display switches (mirrors the Settings toggles).
enum SizeMode {
    static var countICloud = UserDefaults.standard.object(forKey: "countICloud") as? Bool ?? true
    static var allowDownloads = UserDefaults.standard.bool(forKey: "allowDownloads")
    static func sync(_ count: Bool, _ downloads: Bool) {
        countICloud = count
        allowDownloads = downloads
    }
}

struct MediaItem: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let asset: PHAsset
    let local: Int64
    let total: Int64

    /// Size shown and sorted by: includes iCloud-only parts when that setting is on.
    var size: Int64 { SizeMode.countICloud ? total : local }

    var isVideo: Bool { asset.mediaType == .video }
    var isScreenshot: Bool { asset.mediaSubtypes.contains(.photoScreenshot) }
    var isLive: Bool { asset.mediaSubtypes.contains(.photoLive) }
    var isBurst: Bool { asset.representsBurst }
    var date: Date { asset.creationDate ?? .distantPast }

    static func == (l: MediaItem, r: MediaItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct SectionData: Identifiable {
    let id: String
    let title: String?
    let items: [MediaItem]
}

struct Part: Identifiable {
    var id: String { label }
    let label: String
    let bytes: Int64
    let local: Bool
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

extension PHAssetResource {
    // Undocumented but widely used KVC keys; guarded so a missing key can't crash.
    var sizeBytes: Int64 {
        guard responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        return (value(forKey: "fileSize") as? CLong).map(Int64.init) ?? 0
    }
    var isLocal: Bool {
        guard responds(to: NSSelectorFromString("locallyAvailable")) else { return true }
        return (value(forKey: "locallyAvailable") as? Bool) ?? true
    }
}

// MARK: - Toast (top banner, disappears after 3 s)

@MainActor
final class Toaster: ObservableObject {
    @Published var text: String?
    private var token = 0

    func show(_ s: String) {
        token += 1
        let mine = token
        text = s
        Task {
            try? await Task.sleep(for: .seconds(3))
            if mine == token { text = nil }
        }
    }
}

struct ToastLayer: ViewModifier {
    @ObservedObject var toaster: Toaster
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let t = toaster.text {
                    Text(t)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.88), in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: toaster.text)
    }
}

extension View {
    func toastLayer(_ t: Toaster) -> some View { modifier(ToastLayer(toaster: t)) }
}

// MARK: - Image analysis (blur + perceptual hash), fully on-device

enum Analyzer {
    static func run(_ batch: [PHAsset]) -> [(String, Float, String)?] {
        var out = [(String, Float, String)?](repeating: nil, count: batch.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: batch.count) { i in
            autoreleasepool {
                let r = analyze(batch[i])
                lock.lock(); out[i] = r; lock.unlock()
            }
        }
        return out
    }

    static func analyze(_ asset: PHAsset) -> (String, Float, String) {
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false          // never touches the network
        var img: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 192, height: 192),
            contentMode: .aspectFill,
            options: opts
        ) { i, _ in img = i }

        let side = 128
        guard let cg = img?.cgImage, let g = grayBuffer(cg, side: side) else {
            return (asset.localIdentifier, 0, "-")
        }
        let blur = laplacianVariance(g, side: side)
        let h = dHash(g, side: side)
        return (asset.localIdentifier, blur, String(h, radix: 16))
    }

    static func grayBuffer(_ cg: CGImage, side: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: side * side)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(
                data: p.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? buf : nil
    }

    static func laplacianVariance(_ g: [UInt8], side: Int) -> Float {
        var sum = 0.0, sumSq = 0.0
        var n = 0.0
        g.withUnsafeBufferPointer { p in
            for y in 1..<(side - 1) {
                for x in 1..<(side - 1) {
                    let i = y * side + x
                    let v = 4 * Int(p[i]) - Int(p[i - 1]) - Int(p[i + 1]) - Int(p[i - side]) - Int(p[i + side])
                    let d = Double(v)
                    sum += d; sumSq += d * d; n += 1
                }
            }
        }
        let mean = sum / n
        return Float(sumSq / n - mean * mean)
    }

    /// 64-bit difference hash from a 9x8 grid of block averages.
    static func dHash(_ g: [UInt8], side: Int) -> UInt64 {
        var cells = [Double](repeating: 0, count: 9 * 8)
        for cy in 0..<8 {
            let y0 = cy * side / 8, y1 = (cy + 1) * side / 8
            for cx in 0..<9 {
                let x0 = cx * side / 9, x1 = (cx + 1) * side / 9
                var s = 0, c = 0
                for y in y0..<y1 { for x in x0..<x1 { s += Int(g[y * side + x]); c += 1 } }
                cells[cy * 9 + cx] = Double(s) / Double(max(c, 1))
            }
        }
        var h: UInt64 = 0
        var bit: UInt64 = 0
        for cy in 0..<8 {
            for cx in 0..<8 {
                if cells[cy * 9 + cx] > cells[cy * 9 + cx + 1] { h |= (1 << bit) }
                bit += 1
            }
        }
        return h
    }
}

struct DupCandidate: @unchecked Sendable {
    let item: MediaItem
    let hash: UInt64
}

enum DuplicateFinder {
    /// Groups photos with identical pixel size and near-identical hash (Hamming distance <= 3).
    /// Uses 4x16-bit multi-index buckets so it stays fast on large libraries.
    static func groups(_ c: [DupCandidate]) -> [[MediaItem]] {
        var byDim: [String: [Int]] = [:]
        for (i, x) in c.enumerated() {
            byDim["\(x.item.asset.pixelWidth)x\(x.item.asset.pixelHeight)", default: []].append(i)
        }
        var parent = Array(0..<c.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for (_, idxs) in byDim where idxs.count > 1 {
            for chunk in 0..<4 {
                var buckets: [UInt16: [Int]] = [:]
                for i in idxs {
                    buckets[UInt16((c[i].hash >> UInt64(chunk * 16)) & 0xFFFF), default: []].append(i)
                }
                for (_, b) in buckets where b.count > 1 && b.count <= 200 {
                    for x in 0..<b.count {
                        for y in (x + 1)..<b.count {
                            if (c[b[x]].hash ^ c[b[y]].hash).nonzeroBitCount <= 3 { union(b[x], b[y]) }
                        }
                    }
                }
            }
        }
        var roots: [Int: [MediaItem]] = [:]
        for i in 0..<c.count { roots[find(i), default: []].append(c[i].item) }
        var result = roots.values.filter { $0.count > 1 }.map { $0.sorted { $0.size > $1.size } }
        result.sort { a, b in
            let sa = a.dropFirst().reduce(Int64(0)) { $0 + $1.size }
            let sb = b.dropFirst().reduce(Int64(0)) { $0 + $1.size }
            return sa > sb
        }
        return result
    }
}

// MARK: - Library model

@MainActor
final class LibraryModel: ObservableObject {
    enum Policy {
        case launch(autoRefresh: Bool)
        case incremental
        case full
    }

    @Published var items: [MediaItem] = []
    @Published var version = 0
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var denied = false
    @Published var pendingCount = 0

    @Published var analyzing = false
    @Published var analysisDone = 0
    @Published var analysisTotal = 0
    @Published var analysisVersion = 0
    @Published var dupGroups: [[MediaItem]] = []

    private(set) var recs: [String: Rec] = [:]
    private(set) var hasLoadedOnce = false
    private var cacheLoaded = false
    private var pending: [PHAsset] = []
    private var analysisTask: Task<Void, Never>?

    // MARK: Loading

    func refresh(_ policy: Policy) async {
        guard !isLoading else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            denied = true
            return
        }
        denied = false
        isLoading = true
        progress = 0
        defer { isLoading = false }

        if !cacheLoaded {
            recs = await Task.detached(priority: .userInitiated) { Self.loadCache() }.value
            cacheLoaded = true
        }
        if case .full = policy {
            analysisTask?.cancel()
            analyzing = false
            recs = [:]
            dupGroups = []
        }

        // Enumerate the library (cheap: no file-size lookups) and split into cached / new.
        let snapshot = recs
        let split: ([MediaItem], [PHAsset], [String: Rec]) = await Task.detached(priority: .userInitiated) {
            let assets = Self.fetchAll()
            var known: [MediaItem] = []
            var pend: [PHAsset] = []
            var kept: [String: Rec] = [:]
            known.reserveCapacity(assets.count)
            for a in assets {
                let id = a.localIdentifier
                let mod = a.modificationDate?.timeIntervalSince1970 ?? 0
                if let r = snapshot[id], r.mod == mod {
                    known.append(MediaItem(id: id, asset: a, local: r.local, total: r.total))
                    kept[id] = r
                } else {
                    pend.append(a)
                }
            }
            return (known, pend, kept)
        }.value

        recs = split.2
        items = split.0
        version += 1
        pending = split.1

        let shouldMeasure: Bool
        switch policy {
        case .launch(let auto):
            // Skip the rescan unless the user asked for it, 50+ items are new, or this is the first run.
            shouldMeasure = auto || pending.count >= 50 || (items.isEmpty && !pending.isEmpty)
        case .incremental, .full:
            shouldMeasure = true
        }
        pendingCount = shouldMeasure ? 0 : pending.count

        if shouldMeasure && !pending.isEmpty {
            await measurePending()
        } else if shouldMeasure {
            saveCache()
        }
        hasLoadedOnce = true
        refreshDuplicates()
    }

    private func measurePending() async {
        let list = pending
        var built = items
        let total = max(list.count, 1)
        let chunk = 1000
        for start in stride(from: 0, to: list.count, by: chunk) {
            let part = Array(list[start..<min(start + chunk, list.count)])
            let measured: [(String, Rec)] = await Task.detached(priority: .userInitiated) {
                part.map { ($0.localIdentifier, Self.measure($0)) }
            }.value
            for (i, pair) in measured.enumerated() {
                recs[pair.0] = pair.1
                built.append(MediaItem(id: pair.0, asset: part[i], local: pair.1.local, total: pair.1.total))
            }
            items = built
            version += 1
            progress = Double(min(start + chunk, list.count)) / Double(total)
        }
        pending = []
        pendingCount = 0
        saveCache()
    }

    nonisolated static func fetchAll() -> [PHAsset] {
        let o = PHFetchOptions()
        o.includeAllBurstAssets = false
        o.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let r = PHAsset.fetchAssets(with: o)
        var out: [PHAsset] = []
        out.reserveCapacity(r.count)
        r.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    nonisolated static func measure(_ asset: PHAsset) -> Rec {
        var local: Int64 = 0
        var total: Int64 = 0
        for res in PHAssetResource.assetResources(for: asset) {
            let n = res.sizeBytes
            total += n
            if res.isLocal { local += n }
        }
        return Rec(local: local, total: total,
                   mod: asset.modificationDate?.timeIntervalSince1970 ?? 0,
                   blur: nil, hash: nil)
    }

    nonisolated static func breakdown(of asset: PHAsset) -> [Part] {
        var bytes: [String: Int64] = [:]
        var local: [String: Bool] = [:]
        var order: [String] = []
        for res in PHAssetResource.assetResources(for: asset) {
            let label: String
            switch res.type {
            case .photo: label = "Original photo"
            case .fullSizePhoto: label = "Edited photo"
            case .alternatePhoto: label = "Alternate photo"
            case .pairedVideo: label = "Live video"
            case .fullSizePairedVideo: label = "Edited Live video"
            case .video: label = "Original video"
            case .fullSizeVideo: label = "Edited video"
            case .adjustmentData: label = "Edit data"
            default: label = "Other"
            }
            if bytes[label] == nil { order.append(label) }
            bytes[label, default: 0] += res.sizeBytes
            local[label] = (local[label] ?? true) && res.isLocal
        }
        return order.compactMap { l in
            guard let b = bytes[l], b > 0 else { return nil }
            return Part(label: l, bytes: b, local: local[l] ?? true)
        }
    }

    // MARK: Cache

    nonisolated static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache-v1.json")
    }

    nonisolated static func loadCache() -> [String: Rec] {
        guard let d = try? Data(contentsOf: cacheURL),
              let r = try? JSONDecoder().decode([String: Rec].self, from: d) else { return [:] }
        return r
    }

    func saveCache() {
        let snapshot = recs
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(snapshot) {
                try? d.write(to: Self.cacheURL, options: .atomic)
            }
        }
    }

    // MARK: Blur + duplicates analysis

    func blur(of id: String) -> Float? {
        guard let r = recs[id], r.hash != "-" else { return nil }
        return r.blur
    }

    func startAnalysis() {
        guard !analyzing else { return }
        let targets = items
            .filter { !$0.isVideo && recs[$0.id]?.hash == nil }
            .map(\.asset)
        guard !targets.isEmpty else { return }
        analyzing = true
        analysisDone = 0
        analysisTotal = targets.count
        analysisTask = Task {
            var processed = 0
            let batchSize = 240
            for start in stride(from: 0, to: targets.count, by: batchSize) {
                if Task.isCancelled { break }
                let batch = Array(targets[start..<min(start + batchSize, targets.count)])
                let results: [(String, Float, String)?] = await Task.detached(priority: .utility) {
                    Analyzer.run(batch)
                }.value
                for r in results {
                    if let r, var rec = recs[r.0] {
                        rec.blur = r.1
                        rec.hash = r.2
                        recs[r.0] = rec
                    }
                }
                processed += batch.count
                analysisDone = processed
                analysisVersion += 1
                if processed % 2400 == 0 {
                    saveCache()
                    refreshDuplicates()
                }
            }
            analyzing = false
            saveCache()
            refreshDuplicates()
            analysisVersion += 1
        }
    }

    func resetAnalysis() {
        analysisTask?.cancel()
        analyzing = false
        for k in recs.keys {
            recs[k]?.blur = nil
            recs[k]?.hash = nil
        }
        dupGroups = []
        analysisVersion += 1
        saveCache()
        startAnalysis()
    }

    func refreshDuplicates() {
        let cands: [DupCandidate] = items.compactMap { it in
            guard !it.isVideo, !it.isScreenshot,
                  let hs = recs[it.id]?.hash, hs != "-",
                  let h = UInt64(hs, radix: 16),
                  h.nonzeroBitCount > 6, h.nonzeroBitCount < 58 else { return nil }
            return DupCandidate(item: it, hash: h)
        }
        Task.detached(priority: .utility) {
            let groups = DuplicateFinder.groups(cands)
            await MainActor.run {
                self.dupGroups = groups
                self.analysisVersion += 1
            }
        }
    }

    // MARK: Delete

    /// Returns freed bytes, or nil if the user declined the system prompt / it failed.
    func delete(ids: Set<String>) async -> Int64? {
        let targets = items.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return 0 }
        let freed = targets.reduce(Int64(0)) { $0 + $1.size }
        let assets = targets.map(\.asset)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            return nil
        }
        items.removeAll { ids.contains($0.id) }
        for id in ids { recs.removeValue(forKey: id) }
        dupGroups = dupGroups
            .map { g in g.filter { !ids.contains($0.id) } }
            .filter { $0.count > 1 }
        version += 1
        saveCache()
        return freed
    }
}

// MARK: - Section cache

struct Sig: Equatable {
    var version = -1
    var analysisVersion = -1
    var sort: SortKey = .size
    var desc = true
    var blur = 0.0
    var countICloud = true
}

final class ListCache {
    var d: [MediaFilter: [SectionData]] = [:]
    var sig = Sig()
}

struct PreviewRequest: Identifiable {
    let id = UUID()
    let list: [MediaItem]
    let index: Int
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @StateObject private var toaster = Toaster()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("refreshOnLaunch") private var refreshOnLaunch = false
    @AppStorage("blurThreshold") private var blurThreshold = 60.0
    @AppStorage("countICloud") private var countICloud = true
    @AppStorage("allowDownloads") private var allowDownloads = false

    @State private var pageID: MediaFilter? = .all
    @State private var sortKey: SortKey = .size
    @State private var descending = true
    @State private var cache = ListCache()

    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var dragSelecting = false
    @State private var preview: PreviewRequest?
    @State private var showSettings = false

    private var current: MediaFilter { pageID ?? .all }

    // MARK: Data

    private func sections(for f: MediaFilter) -> [SectionData] {
        let sig = Sig(version: model.version, analysisVersion: model.analysisVersion,
                      sort: sortKey, desc: descending, blur: blurThreshold, countICloud: countICloud)
        if cache.sig != sig {
            cache.d.removeAll()
            cache.sig = sig
        }
        if let c = cache.d[f] { return c }
        let s = buildSections(f)
        cache.d[f] = s
        return s
    }

    private func include(_ it: MediaItem, _ f: MediaFilter) -> Bool {
        switch f {
        case .all: return true
        case .videos: return it.isVideo
        case .screenshots: return it.isScreenshot
        case .photos: return !it.isVideo && !it.isScreenshot
        case .live: return it.isLive
        case .burst: return it.isBurst
        case .big: return it.size > 50_000_000
        case .blurry:
            guard !it.isVideo, !it.isScreenshot, let b = model.blur(of: it.id) else { return false }
            return b < Float(blurThreshold)
        case .duplicates: return false
        }
    }

    private func buildSections(_ f: MediaFilter) -> [SectionData] {
        if f == .duplicates {
            return model.dupGroups.enumerated().map { i, g in
                let extra = g.dropFirst().reduce(Int64(0)) { $0 + $1.size }
                return SectionData(
                    id: "dup-\(i)",
                    title: "Group \(i + 1) · \(g.count) photos · \(formatBytes(extra)) extra",
                    items: g
                )
            }
        }
        let base = model.items.filter { include($0, f) }
        let sorted = base.sorted {
            switch sortKey {
            case .size: return descending ? $0.size > $1.size : $0.size < $1.size
            case .date: return descending ? $0.date > $1.date : $0.date < $1.date
            }
        }
        return [SectionData(id: "main", title: nil, items: sorted)]
    }

    private var selectedBytes: Int64 {
        selection.reduce(Int64(0)) { $0 + (model.recs[$1]?.size ?? 0) }
    }

    // MARK: Body

    var body: some View {
        let _ = SizeMode.sync(countICloud, allowDownloads)
        NavigationStack {
            Group {
                if model.denied {
                    ContentUnavailableView(
                        "Photos access needed",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Allow access in Settings › Privacy & Security › Photos.")
                    )
                } else {
                    VStack(spacing: 0) {
                        chipBar
                        if model.isLoading {
                            VStack(spacing: 3) {
                                ProgressView(value: model.progress)
                                Text("Measuring new items… \(Int(model.progress * 100))%")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal).padding(.bottom, 4)
                        } else if model.pendingCount > 0 {
                            HStack {
                                Text("\(model.pendingCount) new items")
                                    .font(.footnote)
                                Spacer()
                                Button("Refresh") { Task { await model.refresh(.incremental) } }
                                    .font(.footnote.weight(.semibold))
                            }
                            .padding(.horizontal).padding(.bottom, 6)
                        }
                        pager
                    }
                }
            }
            .navigationTitle("Photo Cleaner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .task { await model.refresh(.launch(autoRefresh: refreshOnLaunch)) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && model.hasLoadedOnce {
                    Task { await model.refresh(.launch(autoRefresh: refreshOnLaunch)) }
                }
            }
            .onChange(of: pageID) { _, new in
                if new == .blurry || new == .duplicates { model.startAnalysis() }
            }
            .onChange(of: countICloud) { _, _ in model.refreshDuplicates() }
            .fullScreenCover(item: $preview) { req in
                PreviewView(model: model, toaster: toaster, list: req.list, index: req.index)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    model: model,
                    onRefresh: { Task { await model.refresh(.incremental) } },
                    onFull: { Task { await model.refresh(.full) } }
                )
            }
        }
        .toastLayer(toaster)
    }

    // MARK: Chips + pager

    private var chipBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MediaFilter.allCases) { f in
                        Button {
                            withAnimation { pageID = f }
                        } label: {
                            Text(f.rawValue)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .background(current == f ? Color.accentColor : Color.gray.opacity(0.18))
                                .foregroundStyle(current == f ? Color.white : Color.primary)
                                .clipShape(Capsule())
                        }
                        .id("chip-\(f.rawValue)")
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            .onChange(of: pageID) { _, new in
                if let new { withAnimation { proxy.scrollTo("chip-\(new.rawValue)", anchor: .center) } }
            }
        }
    }

    private var pager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(MediaFilter.allCases) { f in
                    GridPage(
                        filter: f,
                        sections: sections(for: f),
                        model: model,
                        selecting: $selecting,
                        selection: $selection,
                        dragSelecting: $dragSelecting,
                        onOpen: { item, list in
                            if let i = list.firstIndex(of: item) {
                                preview = PreviewRequest(list: list, index: i)
                            }
                        },
                        onRefresh: { await model.refresh(.incremental) },
                        onAutoSelectDuplicates: autoSelectDuplicates
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(f)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pageID)
        .scrollDisabled(dragSelecting)
    }

    // MARK: Toolbar / selection bar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Sort by", selection: $sortKey) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                Button {
                    descending.toggle()
                } label: {
                    Label(descending ? "Largest / newest first" : "Smallest / oldest first",
                          systemImage: "arrow.up.arrow.down")
                }
            } label: {
                Label("\(sortKey.rawValue) \(descending ? "↓" : "↑")",
                      systemImage: "arrow.up.arrow.down.circle")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(selecting ? "Cancel" : "Select") {
                selecting.toggle()
                if !selecting { selection.removeAll() }
            }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
    }

    private var selectionBar: some View {
        HStack {
            Button("Select all") {
                selection = Set(sections(for: current).flatMap(\.items).map(\.id))
            }
            Spacer()
            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Label("Delete \(selection.count) · \(formatBytes(selectedBytes))", systemImage: "trash")
                    .font(.body.weight(.semibold))
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal).padding(.vertical, 12)
        .background(.bar)
    }

    private func autoSelectDuplicates() {
        selection = Set(model.dupGroups.flatMap { $0.dropFirst().map(\.id) })
        selecting = true
    }

    private func deleteSelected() {
        let ids = selection
        Task {
            if let freed = await model.delete(ids: ids) {
                selection.removeAll()
                selecting = false
                toaster.show("Deleted \(ids.count) items · freed \(formatBytes(freed))")
            }
        }
    }
}

// MARK: - One swipeable page (grid)

struct FramePref: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

final class FrameStore { var frames: [String: CGRect] = [:] }

struct GridPage: View {
    let filter: MediaFilter
    let sections: [SectionData]
    @ObservedObject var model: LibraryModel
    @Binding var selecting: Bool
    @Binding var selection: Set<String>
    @Binding var dragSelecting: Bool
    let onOpen: (MediaItem, [MediaItem]) -> Void
    let onRefresh: () async -> Void
    let onAutoSelectDuplicates: () -> Void

    @State private var store = FrameStore()
    @State private var dragAdds: Bool?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    private var flat: [MediaItem] { sections.flatMap(\.items) }

    private var summary: String {
        let all = flat
        let bytes = all.reduce(Int64(0)) { $0 + $1.size }
        return "\(all.count) items · \(formatBytes(bytes))\(SizeMode.countICloud ? " incl. iCloud" : " on this iPhone")"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(summary)
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                if filter == .blurry || filter == .duplicates { analysisBanner }
                if filter == .duplicates && !model.dupGroups.isEmpty {
                    Button {
                        onAutoSelectDuplicates()
                    } label: {
                        Label("Auto-select extras (keeps the largest of each group)",
                              systemImage: "checkmark.circle")
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(.bottom, 8)
                }

                if flat.isEmpty {
                    emptyState.padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(sections) { sec in
                            Section {
                                ForEach(sec.items) { item in
                                    cell(item)
                                }
                            } header: {
                                if let t = sec.title {
                                    Text(t)
                                        .font(.footnote.weight(.semibold))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .background(Color.gray.opacity(0.12))
                                }
                            }
                        }
                    }
                    .coordinateSpace(name: "grid")
                    .onPreferenceChange(FramePref.self) { store.frames = $0 }
                    // Long-press, then drag across tiles to select many at once.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.3)
                            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("grid")))
                            .onChanged { value in
                                if case .second(true, let drag) = value {
                                    if !selecting { selecting = true }
                                    dragSelecting = true
                                    if let p = drag?.location { applyDrag(at: p) }
                                }
                            }
                            .onEnded { _ in
                                dragSelecting = false
                                dragAdds = nil
                            }
                    )
                }
            }
        }
        .scrollDisabled(dragSelecting)
        .refreshable { await onRefresh() }
    }

    private func cell(_ item: MediaItem) -> some View {
        Cell(item: item, selecting: selecting, selected: selection.contains(item.id))
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: FramePref.self,
                        value: [item.id: proxy.frame(in: .named("grid"))]
                    )
                }
            )
            .onTapGesture {
                if selecting {
                    if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                } else {
                    onOpen(item, flat)
                }
            }
    }

    private func applyDrag(at point: CGPoint) {
        guard let id = store.frames.first(where: { $0.value.contains(point) })?.key else { return }
        if dragAdds == nil { dragAdds = !selection.contains(id) }
        if dragAdds == true { selection.insert(id) } else { selection.remove(id) }
    }

    @ViewBuilder
    private var analysisBanner: some View {
        if model.analyzing {
            VStack(spacing: 3) {
                ProgressView(value: Double(model.analysisDone), total: Double(max(model.analysisTotal, 1)))
                Text("Analyzing on this iPhone… \(model.analysisDone)/\(model.analysisTotal)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch filter {
        case .blurry:
            ContentUnavailableView("No blurry photos", systemImage: "camera.metering.unknown",
                                   description: Text(model.analyzing ? "Still analyzing…" : "Raise the blur threshold in Settings to flag more."))
        case .duplicates:
            ContentUnavailableView("No duplicates found", systemImage: "square.on.square",
                                   description: Text(model.analyzing ? "Still analyzing…" : "Only photos with the same pixel size and near-identical content are grouped."))
        default:
            ContentUnavailableView("Nothing here", systemImage: "photo")
        }
    }
}

// MARK: - Grid cell

struct Cell: View {
    let item: MediaItem
    let selecting: Bool
    let selected: Bool

    var body: some View {
        Color.gray.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay(Thumbnail(asset: item.asset))
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if item.local < item.total {
                        Image(systemName: "icloud").font(.system(size: 9))
                    }
                    Text(item.size == 0 && item.total > 0 ? "iCloud" : formatBytes(item.size))
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(4)
            }
            .overlay(alignment: .topLeading) {
                if item.isLive {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.yellow)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    let s = Int(item.asset.duration)
                    Text(String(format: "%d:%02d", s / 60, s % 60))
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : Color.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .overlay { if selected { Color.accentColor.opacity(0.25) } }
            .contentShape(Rectangle())
    }
}

struct Thumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .onAppear {
            guard image == nil else { return }
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = false
            requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 240, height: 240),
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                if let img { DispatchQueue.main.async { image = img } }
            }
        }
        .onDisappear {
            if let id = requestID { PHImageManager.default().cancelImageRequest(id) }
            requestID = nil
        }
    }
}

// MARK: - Full-screen preview

struct PreviewView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var toaster: Toaster
    @State private var list: [MediaItem]
    @State private var index: Int
    @State private var dragY: CGFloat = 0
    @State private var zoom: CGFloat = 1
    @State private var parts: [Part] = []
    @Environment(\.dismiss) private var dismiss

    init(model: LibraryModel, toaster: Toaster, list: [MediaItem], index: Int) {
        _model = ObservedObject(wrappedValue: model)
        _toaster = ObservedObject(wrappedValue: toaster)
        _list = State(initialValue: list)
        _index = State(initialValue: index)
    }

    private var current: MediaItem? { list.indices.contains(index) ? list[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item = current {
                media(item)
                    .id(item.id)
                    .offset(y: dragY)
                    .scaleEffect(1 - min(dragY / 1500, 0.15))
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dragGesture)
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomPanel }
        .toastLayer(toaster)
        .onChange(of: current?.id) { _, _ in zoom = 1 }
        .task(id: current?.id) {
            if let c = current { parts = LibraryModel.breakdown(of: c.asset) } else { parts = [] }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func media(_ item: MediaItem) -> some View {
        if item.isVideo {
            VideoView(asset: item.asset)
        } else {
            // Photos, screenshots and Live Photos: pinch / double-tap to zoom, drag to pan.
            ZoomView(scale: $zoom) {
                ZStack {
                    StillView(asset: item.asset, highRes: zoom > 1.5)
                    if item.isLive {
                        LivePhotoPlayer(asset: item.asset)
                            .opacity(zoom > 1.01 ? 0 : 1)
                            .allowsHitTesting(zoom <= 1.01)
                    }
                }
            }
        }
    }

    // Swipe down = close, swipe sideways = previous / next.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                if zoom > 1.01 { return }
                if abs(v.translation.height) > abs(v.translation.width), v.translation.height > 0 {
                    dragY = v.translation.height
                }
            }
            .onEnded { v in
                if zoom > 1.01 { return }
                let dx = v.translation.width
                let dy = v.translation.height
                if abs(dy) > abs(dx), dy > 140 || v.predictedEndTranslation.height > 450 {
                    dismiss()
                } else if abs(dx) > abs(dy), abs(dx) > 70 {
                    step(dx < 0 ? 1 : -1)
                    withAnimation { dragY = 0 }
                } else {
                    withAnimation(.spring) { dragY = 0 }
                }
            }
    }

    private func step(_ d: Int) {
        let n = index + d
        if list.indices.contains(n) { index = n }
    }

    private var topBar: some View {
        HStack {
            Text("\(min(index + 1, list.count)) / \(list.count)")
                .font(.footnote.weight(.semibold))
            Spacer()
            if let d = current?.date, d != .distantPast {
                Text(d.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.black.opacity(0.45))
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if let item = current {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Size: \(formatBytes(item.size))")
                        .font(.headline)
                    if item.total > item.local {
                        Text("On this iPhone: \(formatBytes(item.local)) · iCloud only: \(formatBytes(item.total - item.local))")
                            .font(.caption)
                    }
                    ForEach(parts) { p in
                        Text("\(p.label): \(formatBytes(p.bytes))\(p.local ? "" : " (iCloud only)")")
                            .font(.caption)
                    }
                    if item.isLive {
                        Text("Why so big? A Live Photo = the still photo + a ~3 s video with sound.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.7))
                            .padding(.top, 2)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                actionButton("Close", "xmark", .white.opacity(0.18)) { dismiss() }
                Spacer()
                actionButton("Photos", "photo.on.rectangle", .white.opacity(0.18)) { openPhotos() }
                Spacer()
                actionButton("Delete", "trash", .red.opacity(0.85)) { deleteCurrent() }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(Color.black.opacity(0.6))
    }

    private func actionButton(_ title: String, _ icon: String, _ bg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(bg, in: Capsule())
        }
    }

    /// iOS has no public way to jump to one specific photo, so this opens the Photos app.
    private func openPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }

    private func deleteCurrent() {
        guard let item = current else { return }
        Task {
            if let freed = await model.delete(ids: [item.id]) {
                toaster.show("Deleted 1 item · freed \(formatBytes(freed))")
                if let i = list.firstIndex(where: { $0.id == item.id }) {
                    list.remove(at: i)
                    if list.isEmpty { dismiss() } else { index = min(i, list.count - 1) }
                }
            }
        }
    }
}

// MARK: - Zoom container

struct ZoomView<Content: View>: View {
    @Binding var scale: CGFloat
    let content: Content

    init(scale: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        _scale = scale
        self.content = content()
    }

    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                // Panning only while zoomed in, so swipe-down / swipe-sideways still work at 1x.
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            offset = clamp(CGSize(width: lastOffset.width + v.translation.width,
                                                  height: lastOffset.height + v.translation.height),
                                           geo.size)
                        }
                        .onEnded { _ in lastOffset = offset },
                    including: scale > 1.01 ? .all : .subviews
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            scale = min(max(base * v.magnification, 1), 6)
                            offset = clamp(offset, geo.size)
                        }
                        .onEnded { _ in
                            base = scale
                            if scale < 1.05 {
                                withAnimation(.spring(duration: 0.25)) { reset() }
                            } else {
                                lastOffset = offset
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(duration: 0.3)) {
                        if scale > 1.01 { reset() } else { scale = 2.5; base = 2.5 }
                    }
                }
        }
    }

    private func reset() {
        scale = 1
        base = 1
        offset = .zero
        lastOffset = .zero
    }

    private func clamp(_ o: CGSize, _ size: CGSize) -> CGSize {
        let mx = size.width * (scale - 1) / 2
        let my = size.height * (scale - 1) / 2
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }
}

// MARK: - Media views (thumbnails/analysis never use the network)

struct StillView: View {
    let asset: PHAsset
    var highRes: Bool = false
    @State private var image: UIImage?
    @State private var missing = false
    @State private var loadedHi = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if missing {
                Text("Not stored on this iPhone")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = SizeMode.allowDownloads
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1600, height: 1600),
                contentMode: .aspectFit,
                options: opts
            ) { img, _ in
                DispatchQueue.main.async {
                    if let img { if !loadedHi { image = img } } else if image == nil { missing = true }
                }
            }
        }
        // Zoomed in: swap to a sharper image (up to 4096 px) once.
        .onChange(of: highRes) { _, hi in
            guard hi, !loadedHi else { return }
            loadedHi = true
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.isNetworkAccessAllowed = SizeMode.allowDownloads
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 4096, height: 4096),
                contentMode: .aspectFit,
                options: opts
            ) { img, _ in
                DispatchQueue.main.async {
                    if let img { image = img } else { loadedHi = false }
                }
            }
        }
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.player = player
    }
}

struct VideoView: View {
    let asset: PHAsset
    @State private var player: AVPlayer?
    @State private var missing = false

    var body: some View {
        ZStack {
            if let player {
                PlayerView(player: player)
                    .onTapGesture {
                        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
                    }
            } else if missing {
                Text("Not stored on this iPhone")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = SizeMode.allowDownloads
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: opts) { item, _ in
                DispatchQueue.main.async {
                    if let item {
                        let p = AVPlayer(playerItem: item)
                        player = p
                        p.play()                     // autoplay
                    } else {
                        missing = true
                    }
                }
            }
        }
        .onDisappear { player?.pause() }
    }
}

struct LivePhotoPlayer: UIViewRepresentable {
    let asset: PHAsset

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let v = PHLivePhotoView()
        v.contentMode = .scaleAspectFit
        v.backgroundColor = .clear
        context.coordinator.view = v
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                      action: #selector(Coordinator.tap(_:))))
        let opts = PHLivePhotoRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = SizeMode.allowDownloads
        PHImageManager.default().requestLivePhoto(
            for: asset,
            targetSize: CGSize(width: 1400, height: 1400),
            contentMode: .aspectFit,
            options: opts
        ) { photo, info in
            DispatchQueue.main.async {
                guard let photo else { return }
                v.livePhoto = photo
                if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                    v.startPlayback(with: .full)     // autoplay
                }
            }
        }
        return v
    }

    func updateUIView(_ v: PHLivePhotoView, context: Context) {}

    final class Coordinator: NSObject {
        weak var view: PHLivePhotoView?
        @objc func tap(_ g: UITapGestureRecognizer) {
            view?.startPlayback(with: .full)         // tap to replay
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: LibraryModel
    let onRefresh: () -> Void
    let onFull: () -> Void

    @AppStorage("refreshOnLaunch") private var refreshOnLaunch = false
    @AppStorage("blurThreshold") private var blurThreshold = 60.0
    @AppStorage("countICloud") private var countICloud = true
    @AppStorage("allowDownloads") private var allowDownloads = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Count iCloud items in sizes", isOn: $countICloud)
                    Toggle("Download iCloud originals in preview", isOn: $allowDownloads)
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Count iCloud items: sizes and sorting include parts that live only in iCloud (marked with a cloud icon); deleting a photo removes it from iCloud too. Download originals: lets the preview fetch full-quality iCloud photos and videos. This is the only feature that uses the network, and it is off by default.")
                }

                Section {
                    Toggle("Refresh on launch", isOn: $refreshOnLaunch)
                    Button("Refresh now") { onRefresh(); dismiss() }
                    Button("Rescan everything") { onFull(); dismiss() }
                } header: {
                    Text("Loading")
                } footer: {
                    Text("Off: the app opens instantly from saved results. It still refreshes by itself when 50 or more new items are found. Refresh now only measures new items; Rescan everything starts from scratch.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Blur threshold: \(Int(blurThreshold))")
                        Slider(value: $blurThreshold, in: 10...300, step: 5)
                    }
                    Button("Re-analyze all photos") { model.resetAnalysis(); dismiss() }
                } header: {
                    Text("Blurry & duplicates")
                } footer: {
                    Text("Higher threshold = more photos flagged as blurry. Duplicates are photos with the same pixel size and near-identical content; screenshots are skipped. Photos that exist only in iCloud can't be analyzed.")
                }

                Section {
                    Text("Sizes include Live Photo video and edited versions. With \"Count iCloud items\" off, parts stored only in iCloud count as 0.")
                        .font(.footnote)
                    Text("Everything runs on this iPhone. The network is only used if you turn on iCloud downloads for previews.")
                        .font(.footnote)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
