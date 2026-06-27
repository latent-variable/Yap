import SwiftUI

/// A switch toggle whose ON color stays saturated even when its window isn't key.
///
/// AppKit's stock `NSSwitch` desaturates to gray when its window is inactive.
/// Yap runs as a menu-bar accessory, so the Settings window is frequently *not*
/// the key window (you click another app, then glance back) — which made every
/// "on" toggle look gray and indistinguishable from "off". We draw the switch
/// ourselves so the accent fill is honored regardless of window-active state.
struct StableToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // A plain Button (not a bare .onTapGesture) keeps the control keyboard-
        // navigable (Tab to focus, Space/Return to flip), makes the whole row —
        // including the label — clickable, and preserves VoiceOver traits. The
        // Settings window is promoted to a regular app for keyboard focus, so
        // these matter.
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 8)
                switchTrack(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The switch is hand-drawn (Capsule + Circle), so VoiceOver would
        // otherwise announce a generic "button" with no on/off state. Expose a
        // native Toggle to the accessibility tree for correct role + state.
        .accessibilityRepresentation {
            Toggle(isOn: Binding(get: { configuration.isOn },
                                 set: { configuration.isOn = $0 })) {
                configuration.label
            }
        }
        .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
    }

    private func switchTrack(isOn: Bool) -> some View {
        Capsule()
            // accentColor on a hand-drawn shape is not subject to the inactive-
            // window desaturation that AppKit applies to native controls.
            .fill(isOn ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 38, height: 22)
            .overlay(
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                    .padding(2)
                    .offset(x: isOn ? 8 : -8)
            )
    }
}
