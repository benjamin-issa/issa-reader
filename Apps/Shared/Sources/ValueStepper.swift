import IssaUI
import SwiftUI

/// A numeric stepper that exists on every platform.
///
/// SwiftUI's `Stepper` is unavailable on tvOS, so there it becomes a pair of
/// focusable buttons — which is the right tvOS idiom anyway, since a Siri Remote
/// has nothing to grab on a stepper's split control.
public struct ValueStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    public init(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        format: @escaping (Double) -> String = { "\(Int($0))" },
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    public var body: some View {
        #if os(tvOS)
        HStack {
            Text(title).foregroundStyle(Palette.ink)
            Spacer()
            Button("−") { adjust(-step) }
                .disabled(value - step < range.lowerBound)
            Text(format(value))
                .font(Typography.body.monospacedDigit())
                .frame(minWidth: 90)
            Button("+") { adjust(step) }
                .disabled(value + step > range.upperBound)
        }
        #else
        Stepper(value: $value, in: range, step: step) {
            HStack {
                // The value beside it was always coloured; the title was not,
                // so it took the system label and disappeared in Dark Mode.
                Text(title).foregroundStyle(Palette.ink)
                Spacer()
                Text(format(value))
                    .font(Typography.body.monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        #endif
    }

    private func adjust(_ delta: Double) {
        value = min(max(value + delta, range.lowerBound), range.upperBound)
    }
}
