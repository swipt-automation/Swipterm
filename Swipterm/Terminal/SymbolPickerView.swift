import SwiftUI
import UIKit

struct SymbolPickerView: View {
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category = "all"

    var body: some View {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        let symbols = SymbolCatalog.all.filter { symbol in
            (category == "all" || symbol.categories.contains(category))
                && (query.isEmpty || symbol.name.contains(query) || symbol.keywords.contains { $0.contains(query) })
        }
        SymbolGrid(names: symbols.map(\.name), selection: selection) { name in
            selection = name
            dismiss()
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .top, spacing: 0) {
            categoryBar
        }
        .searchable(text: $query)
        .navigationTitle("Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(SymbolCatalog.categories) { item in
                    let isSelected = category == item.key
                    Button {
                        category = item.key
                    } label: {
                        Label {
                            Text(item.name)
                        } icon: {
                            Image(systemName: item.icon)
                        }
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color.primary.opacity(0.08)),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }
}

private nonisolated enum SymbolCatalog {
    struct Symbol: Identifiable, Sendable {
        let name: String
        let keywords: [String]
        let categories: [String]

        var id: String {
            name
        }
    }

    struct Category: Identifiable, Sendable {
        let key: String
        let icon: String
        let name: LocalizedStringResource

        var id: String {
            key
        }
    }

    private static let bundle = Bundle(identifier: "com.apple.CoreGlyphs")!

    private static let categoryNames: [String: LocalizedStringResource] = [
        "all": "All",
        "whatsnew": "What’s New",
        "communication": "Communication",
        "weather": "Weather",
        "maps": "Maps",
        "objectsandtools": "Objects & Tools",
        "devices": "Devices",
        "cameraandphotos": "Camera & Photos",
        "gaming": "Gaming",
        "connectivity": "Connectivity",
        "transportation": "Transportation",
        "automotive": "Automotive",
        "accessibility": "Accessibility",
        "privacyandsecurity": "Privacy & Security",
        "human": "Human",
        "home": "Home",
        "fitness": "Fitness",
        "nature": "Nature",
        "editing": "Editing",
        "textformatting": "Text Formatting",
        "media": "Media",
        "keyboard": "Keyboard",
        "commerce": "Commerce",
        "time": "Time",
        "health": "Health",
        "shapes": "Shapes",
        "arrows": "Arrows",
        "indices": "Indices",
        "math": "Math",
    ]

    static let categories: [Category] = {
        let entries = NSArray(contentsOf: bundle.url(forResource: "categories", withExtension: "plist")!) as! [[String: String]]
        return entries.compactMap { entry in
            let key = entry["key"]!
            guard let name = categoryNames[key] else { return nil }
            return Category(key: key, icon: entry["icon"]!, name: name)
        }
    }()

    private static let localizedVariants: Set<Substring> = [
        "ar", "bn", "el", "gu", "he", "hi", "ja", "km", "kn", "ko", "ml", "mni", "mr",
        "my", "or", "pa", "rtl", "ru", "sat", "si", "ta", "te", "th", "zh",
    ]

    static let all: [Symbol] = {
        let names = NSArray(contentsOf: bundle.url(forResource: "symbol_order", withExtension: "plist")!) as! [String]
        let keywords = NSDictionary(contentsOf: bundle.url(forResource: "symbol_search", withExtension: "plist")!) as! [String: [String]]
        let categories = NSDictionary(contentsOf: bundle.url(forResource: "symbol_categories", withExtension: "plist")!) as! [String: [String]]
        return names
            .filter { !localizedVariants.contains($0.split(separator: ".").last!) }
            .map { Symbol(name: $0, keywords: keywords[$0] ?? [], categories: categories[$0] ?? []) }
    }()
}

private struct SymbolGrid: UIViewRepresentable {
    let names: [String]
    let selection: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 52, height: 52)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(SymbolCell.self, forCellWithReuseIdentifier: SymbolCell.reuseIdentifier)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        let namesChanged = coordinator.names != names
        guard namesChanged || coordinator.selection != selection else { return }
        coordinator.names = names
        coordinator.selection = selection
        collectionView.reloadData()
        if namesChanged {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var names: [String] = []
        var selection = ""
        var onSelect: (String) -> Void = { _ in }

        func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
            names.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SymbolCell.reuseIdentifier, for: indexPath) as! SymbolCell
            let name = names[indexPath.item]
            cell.configure(name: name, isSelected: name == selection)
            return cell
        }

        func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            onSelect(names[indexPath.item])
        }
    }
}

private final class SymbolCell: UICollectionViewCell {
    static let reuseIdentifier = "symbol"

    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .center
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        contentView.layer.cornerRadius = 12
        contentView.layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.4 : 1 }
    }

    func configure(name: String, isSelected: Bool) {
        imageView.image = UIImage(systemName: name)
        imageView.tintColor = isSelected ? .tintColor : .label
        contentView.backgroundColor = isSelected ? .tintColor.withAlphaComponent(0.18) : nil
        accessibilityLabel = name
    }
}
