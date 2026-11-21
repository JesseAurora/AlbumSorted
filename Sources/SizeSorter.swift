import SwiftUI
import Photos

// MARK: - App

@main
struct SizeSorterApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Model

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case videos = "视频"
    case screenshots = "截图"
    case photos = "照片"
    var id: String { rawValue }
}

struct MediaItem: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let asset: PHAsset
    let size: Int64

    var isVideo: Bool { asset.mediaType == .video }
    var isScreenshot: Bool { asset.mediaSubtypes.contains(.photoScreenshot) }

    static func == (l: MediaItem, r: MediaItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var items: [MediaItem] = []
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
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in assets.append(a) }

        let total = max(assets.count, 1)
        var built: [MediaItem] = []
        built.reserveCapacity(assets.count)

        let chunkSize = 500
        for start in stride(from: 0, to: assets.count, by: chunkSize) {
            let chunk = Array(assets[start..<min(start + chunkSize, assets.count)])
            let part: [MediaItem] = await Task.detached(priority: .userInitiated) {
                chunk.map { MediaItem(id: $0.localIdentifier, asset: $0, size: Self.fileSize(of: $0)) }
            }.value
            built.append(contentsOf: part)
            progress = Double(built.count) / Double(total)
        }

        items = built
        isLoading = false
    }

    // "fileSize" 是 PHAssetResource 的非公开 KVC 键，但被广泛使用，
    // 且无需下载 iCloud 原图即可读取大小。
    nonisolated static func fileSize(of asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset).reduce(into: Int64(0)) { sum, res in
            if let n = res.value(forKey: "fileSize") as? CLong { sum += Int64(n) }
        }
    }

    func delete(ids: Set<String>) async -> Bool {
        let targets = items.filter { ids.contains($0.id) }.map(\.asset)
        guard !targets.isEmpty else { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(targets as NSArray)
            }
            items.removeAll { ids.contains($0.id) }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @State private var filter: MediaFilter = .all
    @State private var largestFirst = true
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive

    private var visible: [MediaItem] {
        let filtered = model.items.filter {
            switch filter {
            case .all: return true
            case .videos: return $0.isVideo
            case .screenshots: return $0.isScreenshot
            case .photos: return !$0.isVideo && !$0.isScreenshot
            }
        }
        return filtered.sorted { largestFirst ? $0.size > $1.size : $0.size < $1.size }
    }

    private var totalText: String {
        let bytes = visible.reduce(Int64(0)) { $0 + $1.size }
        return "共 \(visible.count) 项 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private var selectedText: String {
        let bytes = model.items.filter { selection.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
                } else if model.isLoading {
                    VStack(spacing: 12) {
                        ProgressView(value: model.progress)
                            .padding(.horizontal, 40)
                        Text("正在统计相册大小… \(Int(model.progress * 100))%")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("类型", selection: $filter) {
                            ForEach(MediaFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding([.horizontal, .top])

                        Text(totalText)
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.vertical, 6)

                        List(visible, selection: $selection) { item in
                            Row(item: item)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("大小排序")
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        largestFirst.toggle()
                    } label: {
                        Label(largestFirst ? "从大到小" : "从小到大",
                              systemImage: largestFirst ? "arrow.down" : "arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .bottomBar) {
                    if editMode == .active {
                        Button(role: .destructive) {
                            Task {
                                if await model.delete(ids: selection) { selection.removeAll() }
                            }
                        } label: {
                            Label("删除 \(selection.count) 项（\(selectedText)）", systemImage: "trash")
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
        }
    }
}

struct Row: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(asset: item.asset)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.headline)
                Text(kind).font(.subheadline).foregroundStyle(.secondary)
                if let date = item.asset.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var kind: String {
        if item.isVideo {
            let s = Int(item.asset.duration)
            return String(format: "视频 · %d:%02d", s / 60, s % 60)
        }
        return item.isScreenshot ? "截图" : "照片"
    }
}

struct Thumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .onAppear {
            guard image == nil else { return }
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 192, height: 192),
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                if let img { image = img }
            }
        }
    }
}
