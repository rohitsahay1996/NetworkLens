//
//  RunBar.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 28/08/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// The run's controls, over the app rather than inside the sheet.
///
/// A tester mid-pass is looking at the app, not at the tool. Putting Capture
/// behind the bubble, a tab and a row would make a nine-state pass forty-odd
/// taps, most of them navigation — which is how a feature like this ends up
/// unused while everyone keeps taking manual screenshots.
///
/// Sits above the bubble and moves with it, because the tester has already put
/// the bubble somewhere it does not cover what they are watching.
struct RunBar: View {

    @ObservedObject var runner: ScenarioRunner
    let scene: UIWindowScene?

    @State private var note = ""
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if runner.isReviewing {
                review
            } else {
                actions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .shadow(radius: 6, y: 2)
        .frame(maxWidth: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(runner.progress)
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.secondary)

            Text(runner.current?.name ?? "—")
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                runner.finish()
                runner.stop()
            } label: {
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("End the run")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                runner.capture(in: scene)
            } label: {
                Label("Capture", systemImage: "camera")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(runner.isLast ? "Finish" : "Next") {
                if runner.isLast {
                    runner.finish()
                    runner.stop()
                } else {
                    runner.next()
                }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 0)
        }
    }

    /// Shown only after a capture. Verdict is optional on purpose: a tester
    /// collecting screenshots for someone else to judge should not be forced to
    /// judge, and a forced verdict is a meaningless one.
    private var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                verdictButton(.pass, "checkmark", .green)
                verdictButton(.fail, "xmark", .red)

                Spacer(minLength: 0)

                Button(runner.isLast ? "Finish" : "Next") {
                    commitNote()
                    if runner.isLast {
                        runner.finish()
                        runner.stop()
                    } else {
                        runner.next()
                        note = ""
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            TextField("What did you see?", text: $note)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
                .focused($isNoteFocused)
                .submitLabel(.done)
                .onSubmit { commitNote() }
        }
    }

    private func verdictButton(
        _ verdict: ScenarioRun.Capture.Verdict,
        _ symbol: String,
        _ tint: Color
    ) -> some View {
        let isSelected = runner.currentCapture?.verdict == verdict
        return Button {
            runner.setVerdict(isSelected ? .unset : verdict)
        } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? Color.white : tint)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? tint : tint.opacity(0.15))
                )
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(verdict == .pass ? "Pass" : "Fail")
    }

    private func commitNote() {
        isNoteFocused = false
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runner.setNote(trimmed)
    }
}
#endif
