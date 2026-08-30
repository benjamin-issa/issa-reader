import CoreImage.CIFilterBuiltins
import IssaCore
import IssaUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shows the user code to type, and on TV the QR to scan.
///
/// The user code leads deliberately. Storyteller's `verification_uri_complete`
/// — and therefore its QR — embeds the `device_code`, which is the polling
/// secret rather than the user code RFC 8628 specifies. Anyone who photographs
/// the screen can race the app for the session that approval mints, so the code
/// is the primary affordance and the QR is offered as a convenience — and the
/// QR encodes only the plain `verification_uri`, never the complete one, so
/// scanning saves typing an address rather than handing over the secret.
public struct DeviceCodeView: View {
    let model: DeviceSignInModel
    let onGranted: (String) -> Void
    let onCancel: () -> Void

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

    /// tvOS has no text selection, so the URL is plain there.
    @ViewBuilder
    private func verificationLink(_ uri: String) -> some View {
        let label = Text(uri)
            .font(Typography.body.monospaced())
            .foregroundStyle(Palette.tangerinePressed)
        #if os(tvOS)
        label
        #else
        label.textSelection(.enabled)
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

    private func approval(_ auth: DeviceAuthorization) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Approve this device").overlineStyle(Palette.tangerine)
                // Three steps in order, rather than one instruction with the
                // address printed below the code it refers to.
                step(1) { Text("Go to ") + Text(auth.verificationURI).bold() + Text(" on your phone or computer.") }
                step(2) { Text("Enter the code below.") }
                step(3) { Text("Approve this device.") }
            }

            Text(auth.userCode)
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
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

            // Secondary to the code, and generated rather than fetched: the
            // server offers an SVG, which neither AsyncImage nor UIImage can
            // load, and tvOS — where typing a URL is worst — has no WebKit to
            // render one with.
            // The plain address, NOT `verificationURIComplete`. That one
            // embeds the device_code — the polling secret, as the note above
            // records — and a QR is machine-readable across a room, which makes
            // a photographed screen strictly easier to exploit than one showing
            // a URL and a short code. Scanning saves typing the address; the
            // code is still typed, which is the point of it leading.
            if let qr = Self.qrImage(for: auth.verificationURI) {
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    Text("Or scan this").font(Typography.footnote)
                        .foregroundStyle(Palette.inkTertiary)
                    qr
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 132, height: 132)
                        .padding(Metrics.spacing8)
                        .background(.white, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall))
                        .accessibilityLabel("QR code linking to \(auth.verificationURI)")
                }
            }

            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                Text("Or type the address").font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
                verificationLink(auth.verificationURI)
            }

            HStack(spacing: Metrics.spacing12) {
                ProgressView().controlSize(.small)
                Text("Waiting for approval…")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                Spacer()
                Button("Cancel", action: onCancel).font(Typography.footnote)
            }
        }
    }
}
