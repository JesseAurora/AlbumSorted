import SwiftUI
import Photos
import AVKit

// MARK: - App

@main
struct SizeSorterApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Types

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case videos = "视频"
    case screenshots = "截图"
    case photos = "照片"
    case live = "实况照片"
    case burst = "连拍"
    case big = "大于50MB"
    var id: String { rawValue }
}

enum SortKey: String, CaseIterable, Identifiable {
    case size = "按大小"
    case date = "按日期"
    var id: String { rawValue }
}

struct MediaItem: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let asset: PHAsset
    let size: Int64

    var isVideo: Bool { asset.mediaType == .video }
    var isScreenshot: Bool { asset.mediaSubtypes.contains(.photoScreenshot) }
    var isLive: Bool { asset.mediaSubtypes.contains(.photoLive) }
    var isBurst: Bool { asset.representsBurst }
    var date: Date { asset.creationDate ?? .distantPast }

    static func == (l: MediaItem, r: MediaItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct ShareBundle: Identifiable {
    let id = UUID()
    let urls: [URL]
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

// MARK: - Model

@MainActor
final class LibraryModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var version = 0            // bumped whenever `items` changes
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var denied = false

    func load() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            denied = true
            return
        }
        denied = false
        isLoading = true
        progress = 0

        let options = PHFetchOptions()
        options.includeAllBurstAssets = false
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        let count = result.count
        let total = max(count, 1)

        var built: [MediaItem] = []
        built.reserveCapacity(count)

        // Measure in chunks; publish after each chunk so results appear while scanning
        // and memory stays flat on very large libraries.
        let chunkSize = 1000
        for start in stride(from: 0, to: count, by: chunkSize) {
            let end = min(start + chunkSize, count)
            let indexes = IndexSet(integersIn: start..<end)
            let part: [MediaItem] = await Task.detached(priority: .userInitiated) {
                var out: [MediaItem] = []
                out.reserveCapacity(end - start)
                result.enumerateObjects(at: indexes, options: []) { a, _, _ in
                    out.append(MediaItem(id: a.localIdentifier, asset: a, size: Self.fileSize(of: a)))
                }
                return out
            }.value
            built.append(contentsOf: part)
            items = built
            version += 1
            progress = Double(built.count) / Double(total)
        }
        isLoading = false
    }

    // "fileSize" is an undocumented KVC key on PHAssetResource, but it is widely used
    // and reads sizes without downloading iCloud originals.
    nonisolated static func fileSize(of asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset).reduce(into: Int64(0)) { sum, res in
            if let n = res.value(forKey: "fileSize") as? CLong { sum += Int64(n) }
        }
    }

    nonisolated static func breakdown(of asset: PHAsset) -> [(String, Int64)] {
        var dict: [String: Int64] = [:]
        var order: [String] = []
        for res in PHAssetResource.assetResources(for: asset) {
            let label: String
            switch res.type {
            case .photo: label = "原始照片"
            case .fullSizePhoto: label = "编辑后的照片"
            case .alternatePhoto: label = "备用照片"
            case .pairedVideo: label = "实况视频"
            case .fullSizePairedVideo: label = "编辑后的实况视频"
            case .video: label = "原始视频"
            case .fullSizeVideo: label = "编辑后的视频"
            default: label = "其他"
            }
            let n = (res.value(forKey: "fileSize") as? CLong).map(Int64.init) ?? 0
            if dict[label] == nil { order.append(label) }
            dict[label, default: 0] += n
        }
        return order.map { ($0, dict[$0] ?? 0) }.filter { $0.1 > 0 }
    }

    /// Returns freed bytes, or nil if the user cancelled / it failed.
    func delete(ids: Set<String>) async -> Int64? {
        let targets = items.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return 0 }
        let freed = targets.reduce(Int64(0)) { $0 + $1.size }
        let assets = targets.map(\.asset)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            items.removeAll { ids.contains($0.id) }
            version += 1
            return freed
        } catch {
            return nil
        }
    }

    /// Exports original files to a temp folder so they can be shared (iCloud Drive,
    /// Dropbox, Google Drive, AirDrop...) before deleting.
    nonisolated static func export(_ assets: [PHAsset]) async -> [URL] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (i, asset) in assets.enumerated() {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let res = resources.first(where: { $0.type == .photo || $0.type == .video })
                    ?? resources.first else { continue }
            let url = dir.appendingPathComponent("\(i)-\(res.originalFilename)")
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            let ok: Bool = await withCheckedContinuation { cont in
                PHAssetResourceManager.default().writeData(for: res, toFile: url, options: opts) { error in
                    cont.resume(returning: error == nil)
                }
            }
            if ok { urls.append(url) }
        }
        return urls
    }
}

// MARK: - Drag-select support

final class FrameStore { var frames: [String: CGRect] = [:] }

struct FramePref: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var model = LibraryModel()

    @State private var filter: MediaFilter = .all
    @State private var sortKey: SortKey = .size
    @State private var descending = true
    @State private var visible: [MediaItem] = []

    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var preview: MediaItem?
    @State private var shareBundle: ShareBundle?
    @State private var isExporting = false
    @State private var freedMessage = ""
    @State private var showFreed = false

    @State private var frameStore = FrameStore()
    @State private var dragSelecting = false
    @State private var dragAdds: Bool?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    private func recompute() {
        let f = model.items.filter {
            switch filter {
            case .all: return true
            case .videos: return $0.isVideo
            case .screenshots: return $0.isScreenshot
            case .photos: return !$0.isVideo && !$0.isScreenshot
            case .live: return $0.isLive
            case .burst: return $0.isBurst
            case .big: return $0.size > 50_000_000
            }
        }
        visible = f.sorted {
            switch sortKey {
            case .size: return descending ? $0.size > $1.size : $0.size < $1.size
            case .date: return descending ? $0.date > $1.date : $0.date < $1.date
            }
        }
    }

    private var totalText: String {
        let bytes = visible.reduce(Int64(0)) { $0 + $1.size }
        return "共 \(visible.count) 项 · \(formatBytes(bytes))"
    }

    private var selectedBytes: Int64 {
        visible.reduce(Int64(0)) { selection.contains($1.id) ? $0 + $1.size : $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.denied {
                    ContentUnavailableView(
                        "需要相册权限",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("请在 设置 › 隐私与安全性 › 照片 中允许访问。")
                    )
                } else {
                    VStack(spacing: 0) {
                        filterBar
                        if model.isLoading {
                            VStack(spacing: 4) {
                                ProgressView(value: model.progress)
                                Text("正在统计相册大小… \(Int(model.progress * 100))%")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                        }
                        Text(totalText)
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                        grid
                    }
                }
            }
            .navigationTitle("大小排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await model.load() }
            .onChange(of: model.version) { _, _ in recompute() }
            .onChange(of: filter) { _, _ in recompute() }
            .onChange(of: sortKey) { _, _ in recompute() }
            .onChange(of: descending) { _, _ in recompute() }
            .fullScreenCover(item: $preview) { PreviewView(item: $0) }
            .sheet(item: $shareBundle) { ShareSheet(urls: $0.urls) }
            .alert("删除完成", isPresented: $showFreed) {
                Button("好") {}
            } message: {
                Text(freedMessage)
            }
        }
    }

    // MARK: Filter chips

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaFilter.allCases) { f in
                    Button {
                        filter = f
                    } label: {
                        Text(f.rawValue)
                            .font(.subheadline)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(filter == f ? Color.accentColor : Color.gray.opacity(0.18))
                            .foregroundStyle(filter == f ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(visible) { item in
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
                                toggle(item.id)
                            } else {
                                preview = item
                            }
                        }
                }
            }
            .coordinateSpace(name: "grid")
            .onPreferenceChange(FramePref.self) { frameStore.frames = $0 }
            // Long-press, then drag across cells to select many at once.
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
        .scrollDisabled(dragSelecting)
        .refreshable { await model.load() }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func applyDrag(at point: CGPoint) {
        guard let id = frameStore.frames.first(where: { $0.value.contains(point) })?.key else { return }
        if dragAdds == nil { dragAdds = !selection.contains(id) }
        if dragAdds == true { selection.insert(id) } else { selection.remove(id) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("排序", selection: $sortKey) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                Button {
                    descending.toggle()
                } label: {
                    Label(descending ? "切换为从小到大 / 从旧到新" : "切换为从大到小 / 从新到旧",
                          systemImage: "arrow.up.arrow.down")
                }
            } label: {
                Label(
                    "\(sortKey.rawValue)\(descending ? "↓" : "↑")",
                    systemImage: "arrow.up.arrow.down.circle"
                )
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "取消" : "选择") {
                selecting.toggle()
                if !selecting { selection.removeAll() }
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if selecting {
                Button("全选") { selection = Set(visible.map(\.id)) }
                Spacer()
                Button {
                    Task { await share() }
                } label: {
                    if isExporting { ProgressView() } else { Label("分享", systemImage: "square.and.arrow.up") }
                }
                .disabled(selection.isEmpty || isExporting)
                Spacer()
                Button(role: .destructive) {
                    Task { await deleteSelected() }
                } label: {
                    Label("删除 \(selection.count) 项 · \(formatBytes(selectedBytes))", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    private func share() async {
        isExporting = true
        let assets = visible.filter { selection.contains($0.id) }.map(\.asset)
        let urls = await LibraryModel.export(assets)
        isExporting = false
        if !urls.isEmpty { shareBundle = ShareBundle(urls: urls) }
    }

    private func deleteSelected() async {
        let count = selection.count
        if let freed = await model.delete(ids: selection) {
            selection.removeAll()
            selecting = false
            freedMessage = "已删除 \(count) 项，释放 \(formatBytes(freed))。\n请打开「照片」App，清空「最近删除」才会立即回收空间，否则 iOS 会在 30 天后自动清除。"
            showFreed = true
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
                Text(formatBytes(item.size))
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
            .overlay(alignment: .topLeading) {
                if item.isLive {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.yellow)
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
            opts.isNetworkAccessAllowed = false   // don't pull iCloud originals for a thumbnail
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
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    private let parts: [(String, Int64)]

    init(item: MediaItem) {
        self.item = item
        self.parts = LibraryModel.breakdown(of: item.asset)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Group {
                if item.isVideo {
                    if let player { VideoPlayer(player: player) } else { ProgressView().tint(.white) }
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                player?.pause()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding()
            }
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("总大小 \(formatBytes(item.size))").font(.headline)
                ForEach(parts, id: \.0) { Text("\($0.0)：\(formatBytes($0.1))").font(.caption) }
            }
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.55))
        }
        .onAppear(perform: load)
    }

    private func load() {
        if item.isVideo {
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHImageManager.default().requestPlayerItem(forVideo: item.asset, options: opts) { playerItem, _ in
                if let playerItem {
                    DispatchQueue.main.async { player = AVPlayer(playerItem: playerItem) }
                }
            }
        } else {
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: item.asset,
                targetSize: CGSize(width: 1600, height: 1600),
                contentMode: .aspectFit,
                options: opts
            ) { img, _ in
                if let img { DispatchQueue.main.async { image = img } }
            }
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
