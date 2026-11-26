import CoreImage.CIFilterBuiltins
import SafariServices
import SwiftUI
import UIKit

struct OpenURLPromptModifier: ViewModifier {
    private let system = LinuxSystem.shared

    @State private var pendingWebURL: SheetURL?
    @State private var webURL: SheetURL?

    func body(content: Content) -> some View {
        content
            .sheet(
                item: Binding {
                    system.pendingOpenURL.map(SheetURL.init)
                } set: { item in
                    if item == nil {
                        system.pendingOpenURL = nil
                    }
                },
                onDismiss: {
                    if let pendingWebURL {
                        webURL = pendingWebURL
                        self.pendingWebURL = nil
                    }
                }
            ) { item in
                OpenURLSheet(url: item.url) { url in
                    pendingWebURL = SheetURL(url: url)
                    system.pendingOpenURL = nil
                }
            }
            .sheet(item: $webURL) { item in
                SafariView(url: item.url)
                    .ignoresSafeArea()
            }
    }
}

private struct SheetURL: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

private struct OpenURLSheet: View {
    private enum Route: Hashable {
        case qrCode
    }

    let url: URL
    let onOpenInAppWeb: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var path: [Route] = []
    @State private var formHeight: CGFloat?
    @State private var navBarHeight: CGFloat = 56
    @State private var sheetWidth: CGFloat = 0

    private var isWebURL: Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            true
        default:
            false
        }
    }

    private var activeDetents: Set<PresentationDetent> {
        if !path.isEmpty, sheetWidth > 0 {
            return [.height((navBarHeight + min(sheetWidth, 420)).rounded(.up))]
        }
        if let formHeight {
            return [.height(formHeight)]
        }
        return [.medium]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Text(verbatim: url.absoluteString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("Actions") {
                    Button {
                        if isWebURL {
                            onOpenInAppWeb(url)
                        } else {
                            dismiss()
                            openURL(url)
                        }
                    } label: {
                        Label("Open", systemImage: "globe")
                    }

                    if isWebURL {
                        Button {
                            dismiss()
                            openURL(url)
                        } label: {
                            Label("Open in Safari", systemImage: "safari")
                        }
                    }

                    NavigationLink(value: Route.qrCode) {
                        Label("QR Code", systemImage: "qrcode")
                    }
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(12)
            .scrollBounceBehavior(.basedOnSize)
            .modifier(FormHeightReaderModifier(formHeight: $formHeight, navBarHeight: $navBarHeight))
            .navigationTitle("Open URL")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .qrCode:
                    URLQRCodeView(url: url)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            sheetWidth = newWidth
        }
        .presentationDetents(activeDetents)
        .presentationDragIndicator(.visible)
    }
}

struct FormHeightReaderModifier: ViewModifier {
    @Binding var formHeight: CGFloat?
    @Binding var navBarHeight: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: CGSize.self) { geometry in
                    CGSize(
                        width: geometry.contentInsets.top,
                        height: geometry.contentSize.height + geometry.contentInsets.top
                    )
                } action: { _, metrics in
                    guard metrics.height > 0 else { return }
                    let topInset = metrics.width.rounded(.up)
                    if topInset > 0, abs(navBarHeight - topInset) > 1 {
                        navBarHeight = topInset
                    }
                    let totalHeight = metrics.height.rounded(.up)
                    if abs((formHeight ?? 0) - totalHeight) > 1 {
                        formHeight = totalHeight
                    }
                }
        } else {
            content
        }
    }
}

private struct URLQRCodeView: View {
    private static let ciContext = CIContext()

    private let qrCode: UIImage?

    init(url: URL) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        if let image = filter.outputImage,
           let cgImage = Self.ciContext.createCGImage(image, from: image.extent)
        {
            qrCode = UIImage(cgImage: cgImage)
        } else {
            qrCode = nil
        }
    }

    var body: some View {
        Group {
            if let qrCode {
                Image(uiImage: qrCode)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("QR Code")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context _: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_: SFSafariViewController, context _: Context) {}
}
