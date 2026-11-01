//
//  WeatherManager.swift
//  boringNotch
//
//  Weather data from Open-Meteo (free, no API key).
//  Location comes from the city set in Settings, or from the IP address when empty.
//

import Combine
import Defaults
import Foundation

struct WeatherHour: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let temperature: Double
    let code: Int
    let precipitationChance: Int
}

struct WeatherSnapshot: Equatable {
    let city: String
    let temperature: Double
    let feelsLike: Double
    let humidity: Int
    let windSpeed: Double
    let code: Int
    let isDay: Bool
    let high: Double
    let low: Double
    let hours: [WeatherHour]
    let updatedAt: Date
}

@MainActor
final class WeatherManager: ObservableObject {
    static let shared = WeatherManager()

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let refreshInterval: TimeInterval = 30 * 60

    private init() {}

    func start() {
        Publishers.Merge3(
            Defaults.publisher(.weatherEnabled, options: []).map { _ in () },
            Defaults.publisher(.weatherCity, options: []).map { _ in () },
            Defaults.publisher(.weatherUnit, options: []).map { _ in () }
        )
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.restart() }
            }
            .store(in: &cancellables)
        restart()
    }

    private func restart() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard Defaults[.weatherEnabled] else {
            snapshot = nil
            return
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard Defaults[.weatherEnabled], !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let location = try await resolveLocation()
                snapshot = try await fetchForecast(for: location)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                NSLog("Weather refresh failed: \(error)")
            }
        }
    }

    var unitSymbol: String { Defaults[.weatherUnit] == .celsius ? "°C" : "°F" }

    // MARK: - Location

    private struct Location {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    private enum WeatherError: LocalizedError {
        case cityNotFound(String)
        case locationUnavailable
        case badResponse

        var errorDescription: String? {
            switch self {
            case .cityNotFound(let city): return "City \"\(city)\" not found"
            case .locationUnavailable: return "Couldn't detect your location"
            case .badResponse: return "Weather service unavailable"
            }
        }
    }

    private func resolveLocation() async throws -> Location {
        let city = Defaults[.weatherCity].trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty {
            return try await geocode(city)
        }
        return try await locationFromIP()
    }

    private func geocode(_ city: String) async throws -> Location {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: city),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        struct Response: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
            }
            let results: [Result]?
        }
        let response: Response = try await fetchJSON(components.url!)
        guard let first = response.results?.first else { throw WeatherError.cityNotFound(city) }
        return Location(name: first.name, latitude: first.latitude, longitude: first.longitude)
    }

    private func locationFromIP() async throws -> Location {
        struct IPWhoIs: Decodable {
            let success: Bool?
            let city: String?
            let latitude: Double?
            let longitude: Double?
        }
        if let result: IPWhoIs = try? await fetchJSON(URL(string: "https://ipwho.is/")!),
           result.success != false,
           let lat = result.latitude, let lon = result.longitude
        {
            return Location(name: result.city ?? "", latitude: lat, longitude: lon)
        }

        struct IPAPI: Decodable {
            let city: String?
            let lat: Double?
            let lon: Double?
        }
        if let result: IPAPI = try? await fetchJSON(URL(string: "http://ip-api.com/json/")!),
           let lat = result.lat, let lon = result.lon
        {
            return Location(name: result.city ?? "", latitude: lat, longitude: lon)
        }
        throw WeatherError.locationUnavailable
    }

    // MARK: - Forecast

    private func fetchForecast(for location: Location) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "temperature_unit", value: Defaults[.weatherUnit].apiValue),
        ]

        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let apparent_temperature: Double
                let relative_humidity_2m: Int
                let weather_code: Int
                let is_day: Int
                let wind_speed_10m: Double
            }
            struct Hourly: Decodable {
                let time: [String]
                let temperature_2m: [Double]
                let weather_code: [Int]
                let precipitation_probability: [Int?]?
            }
            struct Daily: Decodable {
                let temperature_2m_max: [Double]
                let temperature_2m_min: [Double]
            }
            let utc_offset_seconds: Int
            let current: Current
            let hourly: Hourly
            let daily: Daily
        }

        let response: Response = try await fetchJSON(components.url!)

        // Hourly times are local to the location ("yyyy-MM-dd'T'HH:mm") without an offset.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: response.utc_offset_seconds)

        let now = Date()
        var hours: [WeatherHour] = []
        for (index, timeString) in response.hourly.time.enumerated() {
            guard let date = formatter.date(from: timeString),
                  date > now.addingTimeInterval(-3600),
                  index < response.hourly.temperature_2m.count,
                  index < response.hourly.weather_code.count
            else { continue }
            let chance = response.hourly.precipitation_probability?[safe: index] ?? nil
            hours.append(WeatherHour(
                time: date,
                temperature: response.hourly.temperature_2m[index],
                code: response.hourly.weather_code[index],
                precipitationChance: chance ?? 0
            ))
            if hours.count == 6 { break }
        }

        return WeatherSnapshot(
            city: location.name,
            temperature: response.current.temperature_2m,
            feelsLike: response.current.apparent_temperature,
            humidity: response.current.relative_humidity_2m,
            windSpeed: response.current.wind_speed_10m,
            code: response.current.weather_code,
            isDay: response.current.is_day == 1,
            high: response.daily.temperature_2m_max.first ?? response.current.temperature_2m,
            low: response.daily.temperature_2m_min.first ?? response.current.temperature_2m,
            hours: Array(hours.dropFirst()),
            updatedAt: now
        )
    }

    private func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WeatherError.badResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - WMO weather codes

enum WeatherCode {
    static func symbol(for code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: return "cloud.rain.fill"
        case 65, 67, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func description(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81: return "Rain showers"
        case 82: return "Heavy showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm, hail"
        default: return "Unknown"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
