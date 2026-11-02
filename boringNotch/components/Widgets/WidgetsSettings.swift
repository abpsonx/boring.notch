//
//  WidgetsSettings.swift
//  boringNotch
//
//  Settings pages for Weather, Clipboard History and Wellness.
//

import Defaults
import SwiftUI

struct WeatherSettings: View {
    @ObservedObject var weather = WeatherManager.shared
    @Default(.weatherCity) var city
    @Default(.weatherUnit) var unit
    @State private var cityDraft = ""

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .weatherEnabled) {
                    Text("Show weather")
                }
                Defaults.Toggle(key: .showWeatherInHeader) {
                    Text("Show temperature in the notch header")
                }
                Defaults.Toggle(key: .todayTabEnabled) {
                    Text("Show Today tab (weather + wellness)")
                }
            } header: {
                Text("General")
            }

            Section {
                HStack {
                    TextField("City", text: $cityDraft, prompt: Text("Automatic (from IP address)"))
                        .onSubmit { city = cityDraft }
                    Button("Save") { city = cityDraft }
                        .disabled(cityDraft == city)
                }
                Picker("Unit", selection: $unit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                HStack {
                    if let snapshot = weather.snapshot {
                        Text("\(snapshot.city): \(Int(snapshot.temperature.rounded()))\(weather.unitSymbol), \(WeatherCode.description(for: snapshot.code))")
                            .foregroundStyle(.secondary)
                    } else if let error = weather.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Refresh now") { weather.refresh() }
                        .disabled(weather.isLoading)
                }
            } header: {
                Text("Location")
            } footer: {
                Text("Weather data from Open-Meteo. Leave the city empty to detect it automatically.")
            }
        }
        .onAppear { cityDraft = city }
        .accentColor(.effectiveAccent)
        .navigationTitle("Weather")
    }
}

struct ClipboardSettings: View {
    @ObservedObject var clipboard = ClipboardHistoryManager.shared
    @Default(.clipboardHistoryLimit) var limit
    @Default(.watchScreenshots) var watchScreenshots

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .clipboardHistoryEnabled) {
                    Text("Keep clipboard history")
                }
                Stepper(value: $limit, in: 5...100, step: 5) {
                    Text("Remember the last \(limit) items")
                }
                Button("Clear history", role: .destructive) {
                    clipboard.clear()
                }
            } header: {
                Text("Clipboard")
            } footer: {
                Text("History is kept in memory only and cleared when the app quits. Passwords copied from password managers are skipped.")
            }

            Section {
                Defaults.Toggle(key: .watchScreenshots) {
                    Text("Add new screenshots to the history")
                }
                HStack {
                    if let folder = clipboard.screenshotFolder {
                        Label(folder.path, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No folder chosen")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(clipboard.screenshotFolder == nil ? "Choose folder…" : "Change…") {
                        clipboard.chooseScreenshotFolder()
                    }
                    if clipboard.screenshotFolder != nil {
                        Button("Remove") { clipboard.forgetScreenshotFolder() }
                    }
                }
                .disabled(!watchScreenshots)
            } header: {
                Text("Screenshots")
            } footer: {
                Text("Pick the folder macOS saves screenshots to (Desktop by default; check with ⌘⇧5 → Options). Screenshots copied straight to the clipboard (⌃⌘⇧4) show up automatically.")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Clipboard")
    }
}

struct NotesSettings: View {
    @Default(.quickNotesAlertMinutes) var alertMinutes
    @Default(.quickNotesEventMinutes) var eventMinutes

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .quickNotesEnabled) {
                    Text("Show Notes tab")
                }
            } footer: {
                Text("Notes are saved on this Mac. Lines starting with \"-\", \"*\", \"•\" or \"1.\" are added as separate tasks to Reminders.")
            }
            Section {
                Picker("Default event length", selection: $eventMinutes) {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Default alert", selection: $alertMinutes) {
                    Text("None").tag(0)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min before").tag($0) }
                }
            } header: {
                Text("Calendar")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Notes")
    }
}

struct WellnessSettings: View {
    @Default(.breakIntervalMinutes) var breakInterval
    @Default(.breakRepeatMinutes) var breakRepeat
    @Default(.idleResetMinutes) var idleReset
    @Default(.waterIntervalMinutes) var waterInterval
    @Default(.waterGoalML) var waterGoalML
    @Default(.waterGlassML) var waterGlassML
    @Default(.breakReminderEnabled) var breakEnabled
    @Default(.waterReminderEnabled) var waterEnabled

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .breakReminderEnabled) {
                    Text("Remind me to take a break")
                }
                Group {
                    Stepper(value: $breakInterval, in: 15...240, step: 15) {
                        Text("After \(WellnessManager.format(duration: TimeInterval(breakInterval * 60))) of continuous screen time")
                    }
                    Stepper(value: $breakRepeat, in: 5...60, step: 5) {
                        Text("Remind again every \(breakRepeat) min if I keep going")
                    }
                    Stepper(value: $idleReset, in: 1...30) {
                        Text("Count \(idleReset) min without input as a break")
                    }
                }
                .disabled(!breakEnabled)
                Button("Preview break reminder") { WellnessManager.shared.preview(.takeBreak) }
            } header: {
                Text("Break")
            } footer: {
                Text("The timer resets when the screen sleeps or locks, or when you're away from the keyboard and mouse.")
            }

            Section {
                Defaults.Toggle(key: .waterReminderEnabled) {
                    Text("Remind me to drink water")
                }
                Group {
                    Stepper(value: $waterInterval, in: 15...180, step: 15) {
                        Text("Every \(waterInterval) min")
                    }
                    Stepper(value: $waterGoalML, in: 500...5000, step: 250) {
                        Text("Daily target: \(WellnessManager.formatML(waterGoalML))")
                    }
                    Picker("Glass size", selection: $waterGlassML) {
                        ForEach([100, 150, 200, 250, 300, 350, 400, 500, 600, 750, 1000], id: \.self) {
                            Text(WellnessManager.formatML($0)).tag($0)
                        }
                    }
                    Text("≈ \(Int((Double(waterGoalML) / Double(max(50, waterGlassML))).rounded(.up))) glasses a day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!waterEnabled)
                Button("Preview water reminder") { WellnessManager.shared.preview(.drinkWater) }
            } header: {
                Text("Water")
            }

            Section {
                Defaults.Toggle(key: .wellnessReminderSound) {
                    Text("Play a sound")
                }
            } header: {
                Text("Notifications")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Wellness")
    }
}
