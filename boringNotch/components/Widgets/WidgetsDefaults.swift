//
//  WidgetsDefaults.swift
//  boringNotch
//
//  Settings for the Weather, Clipboard History and Wellness features.
//

import Defaults
import Foundation

enum TemperatureUnit: String, CaseIterable, Identifiable, Defaults.Serializable {
    case celsius = "Celsius"
    case fahrenheit = "Fahrenheit"

    var id: String { rawValue }
    var apiValue: String { self == .celsius ? "celsius" : "fahrenheit" }
}

extension Defaults.Keys {
    // MARK: Music
    static let rainbowVisualizer = Key<Bool>("rainbowVisualizer", default: true)
    /// On Macs without a camera notch, scroll the song title through the empty middle.
    static let marqueeInMiddle = Key<Bool>("marqueeInMiddle", default: true)

    // MARK: Weather
    static let weatherEnabled = Key<Bool>("weatherEnabled", default: true)
    /// Empty = detect location automatically from the IP address.
    static let weatherCity = Key<String>("weatherCity", default: "")
    static let weatherUnit = Key<TemperatureUnit>("weatherUnit", default: .celsius)
    static let showWeatherInHeader = Key<Bool>("showWeatherInHeader", default: true)

    // MARK: Clipboard history
    static let clipboardHistoryEnabled = Key<Bool>("clipboardHistoryEnabled", default: true)
    static let clipboardHistoryLimit = Key<Int>("clipboardHistoryLimit", default: 30)
    static let watchScreenshots = Key<Bool>("watchScreenshots", default: true)
    static let screenshotFolderBookmark = Key<Data?>("screenshotFolderBookmark", default: nil)

    // MARK: Wellness
    static let todayTabEnabled = Key<Bool>("todayTabEnabled", default: true)
    static let breakReminderEnabled = Key<Bool>("breakReminderEnabled", default: true)
    static let breakIntervalMinutes = Key<Int>("breakIntervalMinutes", default: 120)
    static let breakRepeatMinutes = Key<Int>("breakRepeatMinutes", default: 20)
    static let idleResetMinutes = Key<Int>("idleResetMinutes", default: 5)
    static let waterReminderEnabled = Key<Bool>("waterReminderEnabled", default: true)
    static let waterIntervalMinutes = Key<Int>("waterIntervalMinutes", default: 60)
    static let waterDailyGoal = Key<Int>("waterDailyGoal", default: 8)
    static let waterCount = Key<Int>("waterCount", default: 0)
    static let waterCountDay = Key<String>("waterCountDay", default: "")
    static let wellnessReminderSound = Key<Bool>("wellnessReminderSound", default: true)
}
