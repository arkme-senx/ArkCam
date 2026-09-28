import SwiftUI
import UIKit

struct MemoryFilmstrip: UIViewRepresentable {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let items: [MemoryItem]
    let selectedID: UUID
    let library: MediaLibrary
    let enabled: Bool
    let onSelect: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Strip {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 40, height: 52)
        layout.minimumLineSpacing = 4
        let view = Strip(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .black
        view.semanticContentAttribute = .forceLeftToRight
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.decelerationRate = .fast
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "memory")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "memoryFilmstrip"
        view.accessibilityLabel = L10n.text("回忆缩略图")
        view.onResize = { [weak coordinator = context.coordinator] view in coordinator?.centerSelection(in: view) }
        return view
    }

    func updateUIView(_ view: Strip, context: Context) {
        let coordinator = context.coordinator
        let languageChanged = coordinator.language != L10n.language
        coordinator.language = L10n.language
        view.accessibilityLabel = L10n.text("回忆缩略图")
        let changed = coordinator.parent.items != items
        let selectedChanged = coordinator.parent.selectedID != selectedID
        coordinator.parent = self
        view.isUserInteractionEnabled = enabled
        if changed { view.reloadData() }
        if changed || selectedChanged || languageChanged {
            for path in view.indexPathsForVisibleItems {
                if let cell = view.cellForItem(at: path) { coordinator.configure(cell, at: path) }
            }
            if !view.isTracking && !view.isDragging && !view.isDecelerating {
                coordinator.centerSelection(in: view)
            }
        }
    }

    final class Strip: UICollectionView {
        var onResize: ((Strip) -> Void)?
        private var previousSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != previousSize, bounds.width > 0 else { return }
            previousSize = bounds.size
            let inset = max(0, (bounds.width - 40) / 2)
            contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            onResize?(self)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var language = L10n.language
        var parent: MemoryFilmstrip
        private var adjusting = false
        private var reportedID: UUID?
        init(_ parent: MemoryFilmstrip) { self.parent = parent; reportedID = parent.selectedID }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { parent.items.count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "memory", for: indexPath)
            configure(cell, at: indexPath)
            return cell
        }

        func configure(_ cell: UICollectionViewCell, at path: IndexPath) {
            guard parent.items.indices.contains(path.item) else { return }
            let item = parent.items[path.item]
            let selected = item.id == parent.selectedID
            cell.contentConfiguration = UIHostingConfiguration {
                MemoryStripThumbnail(item: item, library: parent.library)
                    .frame(width: 40, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? .white : .clear, lineWidth: 2))
                    .opacity(selected ? 1 : 0.65)
            }.margins(.all, 0)
            cell.isAccessibilityElement = true
            cell.accessibilityTraits = .button
            cell.accessibilityLabel = L10n.text(item.kind == .video ? "视频" : item.isLivePhoto ? "实况照片" : "照片")
            cell.accessibilityValue = L10n.text(selected ? "当前" : item.createdAt.formatted(.dateTime.locale(L10n.locale).month().day().hour().minute()))
            cell.accessibilityIdentifier = "filmstrip-\(item.kind.rawValue)-\(item.id)"
        }

        func centerSelection(in view: UICollectionView, animated: Bool = false) {
            guard view.bounds.width > 0, let index = parent.items.firstIndex(where: { $0.id == parent.selectedID }) else { return }
            reportedID = parent.selectedID
            adjusting = true
            view.setContentOffset(CGPoint(x: CGFloat(index) * 44 - view.contentInset.left, y: 0), animated: animated)
            adjusting = false
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard parent.items.indices.contains(indexPath.item), parent.enabled else { return }
            reportedID = parent.items[indexPath.item].id
            parent.onSelect(parent.items[indexPath.item].id)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !adjusting, parent.enabled,
                  scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating,
                  !parent.items.isEmpty else { return }
            let index = nearestIndex(scrollView.contentOffset.x, in: scrollView)
            let id = parent.items[index].id
            guard id != reportedID else { return }
            reportedID = id
            parent.onSelect(id)
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                      targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard !parent.items.isEmpty else { return }
            let index = nearestIndex(targetContentOffset.pointee.x, in: scrollView)
            targetContentOffset.pointee.x = CGFloat(index) * 44 - scrollView.contentInset.left
        }

        private func nearestIndex(_ offset: CGFloat, in scrollView: UIScrollView) -> Int {
            min(parent.items.count - 1, max(0, Int(((offset + scrollView.contentInset.left) / 44).rounded())))
        }
    }
}
