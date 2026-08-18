import SousKit
import SwiftUI

/// Setting the clock before it starts.
///
/// The recipe's own duration is a suggestion, not a measurement: ovens differ,
/// and "10-15 Minuten" had to become one number to be a button at all. So the
/// step's time is where the dial starts, and the cook moves it.
struct TimerSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let stepNumber: Int
    /// What the recipe said, in seconds.
    let suggested: TimeInterval
    let onStart: (TimeInterval) -> Void

    @State private var hours = 0
    @State private var minutes = 0
    @State private var seconds = 0

    private var total: TimeInterval {
        TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                picker
                    .frame(maxHeight: 200)

                if total != suggested, suggested > 0 {
                    Button("Zurück auf \(suggested.cookTimerLabel)") { set(to: suggested) }
                        .font(.footnote)
                }

                Button {
                    onStart(total)
                    dismiss()
                } label: {
                    Label("Timer starten", systemImage: "timer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(total <= 0)

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Schritt \(stepNumber)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .sousAppearance()
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 340)
        #elseif os(iOS)
        .presentationDetents([.medium])
        #endif
        .onAppear { set(to: suggested) }
    }

    /// Three wheels on the phone, the way every other timer on the device
    /// looks. The Mac has no wheel picker, so it counts in steppers.
    @ViewBuilder
    private var picker: some View {
        #if os(macOS)
        Form {
            Stepper("Stunden: \(hours)", value: $hours, in: 0...12)
            Stepper("Minuten: \(minutes)", value: $minutes, in: 0...59)
            Stepper("Sekunden: \(seconds)", value: $seconds, in: 0...59)
        }
        .formStyle(.grouped)
        #else
        HStack(spacing: 0) {
            wheel($hours, range: 0..<13, unit: "Std.")
            wheel($minutes, range: 0..<60, unit: "Min.")
            wheel($seconds, range: 0..<60, unit: "Sek.")
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func wheel(_ value: Binding<Int>, range: Range<Int>, unit: String) -> some View {
        HStack(spacing: 2) {
            Picker(unit, selection: value) {
                ForEach(range, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            Text(unit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    private func set(to duration: TimeInterval) {
        let total = Int(duration.rounded())
        hours = total / 3600
        minutes = total / 60 % 60
        seconds = total % 60
    }
}
