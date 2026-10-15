import SwiftUI

/// Yap's look in one place: the brand colours, and the few pieces every screen
/// is built from (the mark, the status pill, the glass card, the big round
/// action button). The menu, Settings and the README art all draw from these, so
/// a colour change is one edit.
///
/// Two halves, two hues: ears are warm (coral to magenta), voice is cool
/// (violet to indigo). The brand gradient runs from one into the other.
enum Brand {
    static let violet = Color(red: 0.49, green: 0.36, blue: 1.00)   // #7D5CFF
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)   // #4F46E5
    static let magenta = Color(red: 0.86, green: 0.15, blue: 0.47)  // #DB2777
    static let coral = Color(red: 0.98, green: 0.42, blue: 0.36)    // #FA6B5C

    static let gradient = LinearGradient(colors: [violet, magenta, coral],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let earsGradient = LinearGradient(colors: [coral, magenta],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let voiceGradient = LinearGradient(colors: [violet, indigo],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Rounded system type for titles: friendlier than the default, still native.
    static func title(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The app mark: a gradient squircle with a waveform that animates while Yap is
/// busy. The animation is an SF Symbol effect, which the system drives and
/// parks, so an idle menu costs nothing (see AGENTS.md, the layout-loop gotcha).
struct BrandMark: View {
    var size: CGFloat = 34
    var active = false
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Brand.gradient)
            .frame(width: size, height: size)
            // The app icon in miniature: a white speech bubble with a waveform
            // for a mouth (scripts/make_icon.swift draws the full-size one).
            .overlay(
                ZStack {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: size * 0.56))
                        .foregroundStyle(.white)
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.24, weight: .heavy))
                        .foregroundStyle(Brand.gradient)
                        .symbolEffect(.variableColor.iterative.reversing, isActive: active)
                        .offset(y: -size * 0.03)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            )
            .shadow(color: Brand.magenta.opacity(0.35), radius: size * 0.18, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

/// A small capsule saying what Yap is doing, with a coloured dot.
struct StatusPill: View {
    let text: String
    let color: Color
    var busy = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: busy)
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

/// The surface every grouped block sits on: a faint fill with a hairline edge,
/// readable on both the light and dark popover material.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 12
    var padding: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

extension View {
    func glassCard(radius: CGFloat = 12, padding: CGFloat = 10) -> some View {
        modifier(GlassCard(radius: radius, padding: padding))
    }
}

/// The one big round button per half: dictate, or play/pause. Gradient fill,
/// soft glow, a press that gives.
struct OrbButtonStyle: ButtonStyle {
    var gradient: LinearGradient
    var glow: Color
    var size: CGFloat = 52
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(gradient))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: glow.opacity(enabled ? 0.45 : 0), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// A gradient capsule for the primary text action ("Read selection").
struct CapsuleButtonStyle: ButtonStyle {
    var gradient: LinearGradient
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(gradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A quiet round icon button (test voice, stop, settings).
struct GhostIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .frame(width: size, height: size)
            .background(Circle().fill(.primary.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .contentShape(Circle())
    }
}

/// A two-option switch with a sliding gradient thumb: the Ears / Voice toggle.
struct PillSwitch<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, title: String, icon: String, gradient: LinearGradient)]
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let on = o.value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = o.value }
                } label: {
                    Label(o.title, systemImage: o.icon)
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background {
                            if on {
                                Capsule().fill(o.gradient)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.primary.opacity(0.07), in: Capsule())
    }
}
