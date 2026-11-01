//
//  TodayView.swift
//  boringNotch
//
//  Notch tab with the weather card and the wellness (break + water) card.
//

import Defaults
import SwiftUI

struct TodayView: View {
    @Default(.weatherEnabled) var weatherEnabled

    var body: some View {
        HStack(spacing: 10) {
            if weatherEnabled {
                WeatherCard()
            }
            WellnessCard()
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Weather

struct WeatherCard: View {
    @ObservedObject var weather = WeatherManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = weather.snapshot {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: WeatherCode.symbol(for: snapshot.code, isDay: snapshot.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 30))
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Int(snapshot.temperature.rounded()))°")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(WeatherCode.description(for: snapshot.code))
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(snapshot.city.isEmpty ? "—" : snapshot.city, systemImage: "location.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("H \(Int(snapshot.high.rounded()))°  L \(Int(snapshot.low.rounded()))°")
                        Text("Feels \(Int(snapshot.feelsLike.rounded()))° · \(snapshot.humidity)%")
                    }
                    .font(.caption2)
                    .foregroundStyle(.gray)
                }

                HStack(spacing: 0) {
                    ForEach(snapshot.hours.prefix(5)) { hour in
                        VStack(spacing: 3) {
                            Text(hour.time, format: .dateTime.hour())
                                .font(.system(size: 9))
                                .foregroundStyle(.gray)
                            Image(systemName: WeatherCode.symbol(for: hour.code))
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 13))
                                .frame(height: 15)
                            Text("\(Int(hour.temperature.rounded()))°")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else if weather.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cloud.sun")
                        .font(.title2)
                    Text(weather.errorMessage ?? "Weather unavailable")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("Retry") { weather.refresh() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                }
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
        .onTapGesture(count: 2) { weather.refresh() }
    }
}

/// Small "☁️ 29°" chip for the notch header.
struct WeatherHeaderChip: View {
    @ObservedObject var weather = WeatherManager.shared

    var body: some View {
        if let snapshot = weather.snapshot {
            HStack(spacing: 4) {
                Image(systemName: WeatherCode.symbol(for: snapshot.code, isDay: snapshot.isDay))
                    .symbolRenderingMode(.multicolor)
                Text("\(Int(snapshot.temperature.rounded()))°")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .help("\(snapshot.city) · \(WeatherCode.description(for: snapshot.code))")
            .onTapGesture {
                BoringViewCoordinator.shared.currentView = .today
            }
        }
    }
}

// MARK: - Wellness

struct WellnessCard: View {
    @ObservedObject var wellness = WellnessManager.shared
    @Default(.breakReminderEnabled) var breakEnabled
    @Default(.waterReminderEnabled) var waterEnabled
    @Default(.waterDailyGoal) var waterGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reminder = wellness.pendingReminder {
                reminderBanner(reminder)
            } else {
                screenTimeRow
            }
            Divider().overlay(Color.white.opacity(0.08))
            waterRow
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }

    private var screenTimeRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: wellness.breakEndsAt != nil ? 1 : wellness.breakProgress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: wellness.breakEndsAt != nil ? "cup.and.saucer.fill" : "desktopcomputer")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                if let breakEnd = wellness.breakEndsAt {
                    Text("Lagi istirahat")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text("Selesai \(breakEnd, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                } else {
                    Text("Layar aktif \(WellnessManager.format(duration: wellness.continuousScreenTime))")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(breakEnabled
                         ? "Istirahat dalam \(WellnessManager.format(duration: wellness.timeUntilBreak))"
                         : "Pengingat istirahat mati")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
            Spacer(minLength: 0)
            if wellness.breakEndsAt != nil {
                pillButton("Selesai", icon: "checkmark") { wellness.endBreakEarly() }
            } else {
                pillButton("Istirahat", icon: "figure.walk") { wellness.startBreak() }
            }
        }
    }

    private var ringColor: Color {
        if wellness.breakEndsAt != nil { return .green }
        switch wellness.breakProgress {
        case ..<0.75: return .green
        case ..<1: return .orange
        default: return .red
        }
    }

    private func reminderBanner(_ reminder: WellnessReminder) -> some View {
        HStack(spacing: 10) {
            Image(systemName: reminder.icon)
                .font(.system(size: 18))
                .foregroundStyle(reminder.kind == .drinkWater ? Color.cyan : Color.orange)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(reminder.kind == .takeBreak
                     ? "Sudah \(reminder.detail) di depan layar"
                     : "Hari ini \(reminder.detail) gelas")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            Spacer(minLength: 0)
            pillButton("Nanti", icon: "clock") { wellness.snooze() }
            if reminder.kind == .takeBreak {
                pillButton("Oke", icon: "checkmark", prominent: true) { wellness.startBreak() }
            } else {
                pillButton("Sudah", icon: "drop.fill", prominent: true) { wellness.logWater() }
            }
        }
    }

    private var waterRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<max(1, min(waterGoal, 12)), id: \.self) { index in
                    Image(systemName: index < wellness.waterCount ? "drop.fill" : "drop")
                        .font(.system(size: 12))
                        .foregroundStyle(index < wellness.waterCount ? Color.cyan : Color.gray.opacity(0.5))
                }
            }
            Text("\(wellness.waterCount)/\(waterGoal)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.gray)
            Spacer(minLength: 0)
            Button {
                wellness.undoWater()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.gray)
            .disabled(wellness.waterCount == 0)
            pillButton("Minum", icon: "plus", prominent: true) { wellness.logWater() }
        }
    }

    private func pillButton(_ title: String, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(prominent ? Color.white.opacity(0.9) : Color.white.opacity(0.1)))
                .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Closed notch reminder

/// Shown around the closed notch when a reminder fires, like the charging notification.
struct WellnessReminderLiveActivity: View {
    let reminder: WellnessReminder
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: reminder.icon)
                    .foregroundStyle(accent)
                Text(reminder.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 150, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth + 10)

            Text(reminder.detail)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .frame(width: 76, alignment: .trailing)
        }
        .frame(height: height, alignment: .center)
    }

    private var accent: Color {
        reminder.kind == .drinkWater ? .cyan : .orange
    }
}
