import IssaCore
import IssaUI
import SwiftUI

/// Shows the user code to type, and on TV the QR to scan.
///
/// The user code leads deliberately. Storyteller's `verification_uri_complete`
/// — and therefore its QR — embeds the `device_code`, which is the polling
/// secret rather than the user code RFC 8628 specifies. Anyone who photographs
/// the screen can race the app for the session that approval mints, so the code
/// is the primary affordance and the QR is offered as a convenience.
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

    private func approval(_ auth: DeviceAuthorization) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Approve this device").overlineStyle(Palette.tangerine)
                Text("Open the link below and enter this code.")
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
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

            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                Text("On another device, visit").font(Typography.footnote)
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
