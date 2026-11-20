import AppKit

/// The Skin Museum window: a grid of museum skins, searchable and paged as you scroll. Clicking a
/// skin, or moving to it with the arrow keys, puts it on the player at once. ⌘] and ⌘[ step
/// through the same list, with the window open or not.
@MainActor
final class SkinBrowser: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate {
    unowned let app: AppDelegate
    private var window: NSWindow?
    private var grid: NSCollectionView!
    private var search: NSSearchField!
    private var status: NSTextField!

    private(set) var items: [SkinMuseum.Item] = []
    private var query = ""
    private var more = true
    private var total: Int?
    private var loadTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var generation = 0
    /// The skin last put on the player from here (its MD5), to step from with ⌘] and ⌘[.
    private var currentMD5: String?

    init(app: AppDelegate) {
        self.app = app
        // The museum skin on the player at launch, if it is one, so ⌘] carries on from it.
        if let path = UserDefaults.standard.string(forKey: AppDelegate.Keys.skinPath),
           URL(fileURLWithPath: path).deletingLastPathComponent().path == SkinMuseum.skinsFolder.path {
            currentMD5 = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        super.init()
    }

    func show() {
        if window == nil { makeWindow() }
        if items.isEmpty { reload() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(grid)
    }

    // MARK: Window

    private func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Skin Museum"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 330, height: 300)

        search = NSSearchField()
        search.placeholderString = "Search the Winamp Skin Museum"
        search.sendsSearchStringImmediately = false
        search.sendsWholeSearchString = false
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: SkinCell.size.width, height: SkinCell.size.height)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        grid = NSCollectionView()
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = false
        grid.dataSource = self
        grid.delegate = self
        grid.backgroundColors = [.windowBackgroundColor]
        grid.register(SkinCell.self, forItemWithIdentifier: SkinCell.id)
        grid.setAccessibilityLabel("Skins")

        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true

        status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail

        let content = NSView()
        for v in [search!, scroll, status!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        w.contentView = content
        w.setFrameAutosaveName("SkinMuseum")
        if w.frame.origin == .zero { w.center() }
        window = w
    }

    // MARK: Loading

    @objc private func searchChanged() {
        let q = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q != query else { return }
        query = q
        reload()
    }

    private func reload() {
        loadTask?.cancel()
        generation += 1
        items = []
        more = true
        total = nil
        grid?.reloadData()
        loadMore()
    }

    /// Fetches the next page, unless one is on its way or the list is complete.
    func loadMore(then done: (() -> Void)? = nil) {
        guard more, loadTask == nil else { return }
        let gen = generation, q = query, offset = items.count
        setStatus(items.isEmpty ? "Loading\u{2026}" : nil)
        loadTask = Task { [weak self] in
            do {
                let page = try await SkinMuseum.page(query: q, offset: offset)
                guard let self, gen == self.generation else { return }
                self.loadTask = nil
                let known = Set(self.items.map(\.md5))
                let fresh = page.items.filter { !known.contains($0.md5) }
                let start = self.items.count
                self.items += fresh
                self.more = page.more
                if let t = page.total { self.total = t }
                self.grid?.insertItems(at: Set((start..<self.items.count).map { IndexPath(item: $0, section: 0) }))
                if let i = fresh.firstIndex(where: { $0.md5 == self.currentMD5 }) {
                    self.grid?.selectionIndexPaths = [IndexPath(item: start + i, section: 0)]
                }
                self.setStatus(nil)
                done?()
            } catch {
                guard let self, gen == self.generation else { return }
                self.loadTask = nil
                if !Task.isCancelled { self.setStatus("Couldn't reach the museum: \(error.localizedDescription)") }
            }
        }
    }

    private func setStatus(_ text: String?) {
        guard let status else { return }
        if let text { status.stringValue = text; return }
        if items.isEmpty, !more {
            status.stringValue = query.isEmpty ? "The museum has no skins to show." : "No skins match \u{201C}\(query)\u{201D}."
            return
        }
        let count = query.isEmpty ? (total.map { "\($0.formatted()) skins" } ?? "") : "\(items.count)\(more ? "+" : "") matches"
        status.stringValue = "\(count) from skins.webamp.org. Click one, or use the arrow keys, to put it on. ⌘] and ⌘[ step through them."
    }

    // MARK: Applying

    /// Downloads the skin if needed and puts it on the player. A skin that doesn't load leaves the
    /// current one on.
    private func apply(_ item: SkinMuseum.Item) {
        applyTask?.cancel()
        currentMD5 = item.md5
        setStatus("Loading \(item.name)\u{2026}")
        applyTask = Task { [weak self] in
            do {
                let file = try await SkinMuseum.skinFile(item)
                guard let self, !Task.isCancelled else { return }
                if self.app.applySkinFile(file, name: item.name) {
                    self.setStatus(nil)
                } else {
                    self.setStatus("Can't load \(item.name). The player keeps its current skin.")
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.app.show("CAN'T LOAD THIS ONE", seconds: 3)
                self.setStatus("Can't load \(item.name): \(error.localizedDescription)")
            }
        }
    }

    /// ⌘] (+1) and ⌘[ (-1): the next or previous skin in the list, loading the first page if needed.
    func step(_ delta: Int) {
        guard !items.isEmpty else {
            loadMore { [weak self] in self?.step(delta) }
            return
        }
        let at = currentMD5.flatMap { md5 in items.firstIndex { $0.md5 == md5 } }
        let next = at.map { $0 + delta } ?? (delta > 0 ? 0 : items.count - 1)
        guard items.indices.contains(next) else {
            if next >= items.count, more { loadMore { [weak self] in self?.step(delta) } }
            return
        }
        select(next)
        apply(items[next])
        if next >= items.count - 6 { loadMore() }
    }

    private func select(_ index: Int) {
        guard let grid, window?.isVisible == true else { return }
        let path = IndexPath(item: index, section: 0)
        grid.selectionIndexPaths = [path]
        grid.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
    }

    // MARK: Grid

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: SkinCell.id, for: indexPath) as! SkinCell
        cell.show(items[indexPath.item])
        if indexPath.item >= items.count - 12 { loadMore() }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let i = indexPaths.first?.item, items.indices.contains(i), items[i].md5 != currentMD5 else { return }
        apply(items[i])
    }

}

/// One skin in the grid: the main window from its museum screenshot, and its name.
private final class SkinCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("SkinCell")
    static let size = CGSize(width: CGFloat(Layout.size.w), height: CGFloat(Layout.size.h) + 22)

    private let picture = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var md5: String?

    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: Self.size))
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.frame = NSRect(x: 0, y: 22, width: Self.size.width, height: Self.size.height - 22)
        label.frame = NSRect(x: 4, y: 3, width: Self.size.width - 8, height: 16)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .center
        v.addSubview(picture)
        v.addSubview(label)
        view = v
    }

    func show(_ item: SkinMuseum.Item) {
        md5 = item.md5
        label.stringValue = item.name
        view.setAccessibilityLabel(item.name)
        picture.image = SkinMuseum.cachedThumbnail(item)
        guard picture.image == nil else { return }
        Task { [weak self] in
            let img = await SkinMuseum.thumbnail(item)
            guard let self, self.md5 == item.md5 else { return }
            self.picture.image = img
        }
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : nil
            label.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        }
    }
}
