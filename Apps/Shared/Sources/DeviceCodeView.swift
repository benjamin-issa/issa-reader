import CoreImage.CIFilterBuiltins
import IssaCore
import IssaUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shows the code to type, the address to open, and the QR to scan.
///
/// Every route here is pre-filled: the link and the QR both carry the server's
/// `verification_uri_complete`, so approving is one tap or one scan and nobody
/// types anything. That URL embeds the `device_code` — the polling secret,
/// rather than the user code RFC 8628 puts there — which is a real exposure on
/// a television: someone who photographs the screen can race this app for the
/// session the approval mints. It was weighed and accepted; see
/// `DeviceAuthorization.approvalPayload` for the reasoning. The typeable code
/// and address are still shown, because the pre-filled route can always fail.
public struct DeviceCodeView: View {
    let model: DeviceSignInModel
    let onGranted: (String) -> Void
    let onCancel: () -> Void
    /// When the code was last copied, which the caption reflects for a moment.
    @State private var copiedAt: Date?

    public init(
        model: DeviceSignInModel,
        onGranted: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
    ) {
        self.model = model
        self.onGranted = onGranted
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            switch model.stage {
            case .starting:
                ProgressView("Contacting your server…").font(Typography.body)

            case let .awaitingApproval(auth):
                approval(auth)

            case .granted:
                ProgressView("Signing in…").font(Typography.body)

            case let .failed(reason):
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    Text("Couldn't sign in").font(Typography.title).foregroundStyle(Palette.ink)
                    Text(reason).font(Typography.footnote).foregroundStyle(Palette.inkSecondary)
                    Button("Back", action: onCancel).font(Typography.body)
                }
            }
        }
        .onChange(of: model.stage) { _, stage in
            if case let .granted(token) = stage { onGranted(token) }
        }
        .onDisappear { model.cancel() }
    }

    /// The address, as a link where a browser exists.
    ///
    /// The label is the plain address, because that is what a person would
    /// type; the destination is the pre-filled one, so a tap lands on a page
    /// that only asks them to approve. tvOS has no browser and no text
    /// selection, so there it is plain text.
    @ViewBuilder
    private func verificationLink(_ auth: DeviceAuthorization) -> some View {
        let label = Text(auth.verificationURI)
            .font(Typography.body.monospaced())
            .foregroundStyle(Palette.tangerinePressed)
        #if os(tvOS)
        label
        #else
        if let url = auth.approvalURL, url.isWebLink {
            Link(destination: url) { label }
                .accessibilityLabel("Open \(auth.verificationURI) to approve this device")
        } else {
            label.textSelection(.enabled)
        }
        #endif
    }

    /// One numbered instruction.
    private func step(_ number: Int, @ViewBuilder _ text: () -> Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
            Text("\(number).")
                .font(Typography.headline.monospacedDigit())
                .foregroundStyle(Palette.tangerine)
            text()
                .font(Typography.callout)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Renders the approval link as a QR code, locally.
    ///
    /// `DeviceAuthorization.qrSVGURL` exists and is decoded, but nothing has
    /// ever drawn it: SVG is not loadable by any of the image types here, and
    /// tvOS ships no WebKit. CoreImage generates the same payload on every
    /// platform with no network at all.
    static func qrImage(for string: String) -> Image? {
        // Never pass a URL carrying the device code here.

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium correction: the payload is a URL with a code in it, and a
        // denser symbol is harder to scan off a television across a room.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #elseif canImport(AppKit)
        return Image(nsImage: NSImage(cgImage: cgImage, size: output.extent.size))
        #else
        return nil
        #endif
    }

    // MARK: - The approval screen

    private func approval(_ auth: DeviceAuthorization) -> some View {
        // Side by side on a television, so the QR fills the half of a
        // 1920-wide screen that used to sit empty while the instructions
        // huddled against the left edge.
        #if os(tvOS)
        HStack(alignment: .top, spacing: Metrics.spacing32) {
            VStack(alignment: .leading, spacing: Metrics.spacing24) {
                steps(auth)
                codeBlock(auth)
                addressBlock(auth)
                statusRow(auth)
            }
            .frame(maxWidth: 900, alignment: .leading)
            qrBlock(auth)
        }
        #else
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            steps(auth)
            codeBlock(auth)
            qrBlock(auth)
            addressBlock(auth)
            statusRow(auth)
        }
        #endif
    }

    private func steps(_ auth: DeviceAuthorization) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("Approve this device").overlineStyle(Palette.tangerine)
            // Three steps in order, rather than one instruction with the
            // address printed below the code it refers to.
            #if os(tvOS)
            step(1) { Text("Scan the code, or go to ") + Text(auth.verificationURI).bold() + Text(".") }
            step(2) { Text("Enter the code below if you are asked for one.") }
            #else
            step(1) {
                Text("Open ") + Text(auth.verificationURI).bold()
                    + Text(" on this device or another one.")
            }
            step(2) { Text("Enter the code below if you are asked for one.") }
            #endif
            step(3) { Text("Approve this device.") }
        }
    }

    /// The code, and — where there is a pasteboard — a tap that copies it.
    @ViewBuilder
    private func codeBlock(_ auth: DeviceAuthorization) -> some View {
        let code = Text(auth.userCode)
            .font(.system(size: Self.codeSize, weight: .semibold, design: .monospaced))
            .tracking(4)
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.spacing24)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusLarge))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                    .strokeBorder(Palette.border, lineWidth: 1),
            )
            .accessibilityLabel(Text(auth.userCode.map { String($0) }.joined(separator: " ")))

        #if os(tvOS)
        // No pasteboard on tvOS, so no affordance that would do nothing.
        code
        #else
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Button {
                Clipboard.copy(auth.userCode)
                copiedAt = .now
            } label: { code }
                .buttonStyle(.plain)
                .accessibilityHint("Copies the code")
            Text(copiedAt == nil ? "Tap the code to copy it" : "Copied")
                .font(Typography.footnote)
                .foregroundStyle(copiedAt == nil ? Palette.inkTertiary : Palette.moss)
                .accessibilityHidden(copiedAt == nil)
        }
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            copiedAt = nil
        }
        #endif
    }

    /// The QR, generated here rather than fetched: the server offers an SVG,
    /// which neither AsyncImage nor UIImage can load, and tvOS — where typing
    /// is worst — has no WebKit to render one with.
    @ViewBuilder
    private func qrBlock(_ auth: DeviceAuthorization) -> some View {
        if let qr = Self.qrImage(for: auth.approvalPayload) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Or scan this").font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
                qr
                    .interpolation(.none)
                    .resizable()
                    .frame(width: Self.qrSide, height: Self.qrSide)
                    .padding(Metrics.spacing8)
                    .background(.white, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall))
                    .accessibilityLabel("QR code that opens the approval page for this device")
            }
        }
    }

    private func addressBlock(_ auth: DeviceAuthorization) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Text("Or type the address").font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
            verificationLink(auth)
        }
    }

    /// What is happening, and how long this code has left.
    ///
    /// The countdown is not decoration: it is the difference between a screen
    /// that has quietly stopped working and one that says so. When it runs out
    /// the model fetches another code in place, which this row also says.
    private func statusRow(_ auth: DeviceAuthorization) -> some View {
        HStack(spacing: Metrics.spacing12) {
            ProgressView().controlSize(.small)
            if model.isRenewing {
                Text("Getting a fresh code…")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            } else if let expiresAt = model.expiresAt, expiresAt > .now {
                Text("Waiting for approval · ")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    + Text(timerInterval: .now ... expiresAt, countsDown: true)
                    .font(Typography.footnote.monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                Text("Waiting for approval…")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Button("Cancel", action: onCancel).font(Typography.footnote)
        }
        .accessibilityElement(children: .combine)
    }

    /// Sizes the television states outright, because these two are the things
    /// a person reads from a sofa and scans from one.
    #if os(tvOS)
    private static let codeSize: CGFloat = 96
    private static let qrSide: CGFloat = 420
    #else
    private static let codeSize: CGFloat = 44
    private static let qrSide: CGFloat = 132
    #endif
}
