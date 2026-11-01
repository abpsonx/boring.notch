//
//  ChargingAnimationView.swift
//  boringNotch
//
//  Animated closed-notch indicator for plugging in / unplugging the charger:
//  bolt pops in with a pulse, battery ring and bar fill up with a moving shine.
//

import Defaults
import SwiftUI

extension Defaults.Keys {
    static let animatedChargingIndicator = Key<Bool>("animatedChargingIndicator", default: true)
}

struct ChargingAnimationView: View {
    let isPluggedIn: Bool
    let isCharging: Bool
    let level: Float
    let statusText: String
    let notchWidth: CGFloat
    let height: CGFloat

    @State private var appeared = false
    @State private var pulse = false
    @State private var shine: CGFloat = 0

    private let sideWidth: CGFloat = 150
    private var totalWidth: CGFloat { sideWidth * 2 + notchWidth + 10 }
    private var powered: Bool { isPluggedIn || isCharging }
    private var fraction: CGFloat { CGFloat(max(0, min(100, level))) / 100 }

    private var accent: Color {
        if powered { return .green }
        return level <= 20 ? .red : .white
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 0) {
                // Left: icon + status
                HStack(spacing: 8) {
                    ZStack {
                        if powered {
                            Circle()
                                .fill(accent.opacity(0.35))
                                .frame(width: 24, height: 24)
                                .scaleEffect(pulse ? 1.6 : 0.7)
                                .opacity(pulse ? 0 : 0.9)
                        }
                        Image(systemName: powered ? "bolt.fill" : "powerplug.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                            .shadow(color: powered ? accent.opacity(0.8) : .clear, radius: 6)
                            .scaleEffect(appeared ? 1 : 0.1)
                            .rotationEffect(.degrees(appeared ? 0 : (powered ? -40 : 40)))
                    }
                    .frame(width: 24, height: 24)

                    Text(statusText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .opacity(appeared ? 1 : 0)
                        .offset(x: appeared ? 0 : -10)
                }
                .frame(width: sideWidth, alignment: .leading)

                Rectangle()
                    .fill(.black)
                    .frame(width: notchWidth + 10)

                // Right: percentage + ring
                HStack(spacing: 6) {
                    Text("\(Int(level))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .opacity(appeared ? 1 : 0)
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: appeared ? fraction : 0)
                            .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 18, height: 18)
                }
                .frame(width: sideWidth, alignment: .trailing)
            }
            .frame(height: height, alignment: .center)

            // Charging bar with a moving shine
            GeometryReader { geo in
                let filled = geo.size.width * (appeared ? fraction : 0)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(LinearGradient(colors: [accent.opacity(0.55), accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: filled)
                        .overlay(alignment: .leading) {
                            if powered {
                                LinearGradient(colors: [.clear, .white.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 50)
                                    .offset(x: -50 + shine * (filled + 50))
                            }
                        }
                        .clipShape(Capsule())
                        .shadow(color: powered ? accent.opacity(0.6) : .clear, radius: 4)
                }
            }
            .frame(width: totalWidth - 16, height: 5)
            .padding(.bottom, 10)
        }
        .fixedSize()
        .onAppear(perform: animateIn)
        .onChange(of: powered) { _, _ in
            // Replay the entrance when switching between plugged / unplugged.
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                appeared = false
                pulse = false
                shine = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { animateIn() }
        }
    }

    private func animateIn() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) {
            appeared = true
        }
        guard powered else { return }
        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
            pulse = true
        }
        withAnimation(.linear(duration: 1.3).delay(0.4).repeatForever(autoreverses: false)) {
            shine = 1
        }
    }
}
