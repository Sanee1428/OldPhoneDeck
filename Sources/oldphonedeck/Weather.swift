import Foundation

/// Current weather for the places picked on the phone (hold the weather tile),
/// from Open-Meteo (free, no API key). Refreshed every 15 minutes and whenever the list changes.
final class Weather {
    struct Place { let name: String; let lat: Double; let lon: Double }

    static let maxPlaces = 6
    static let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck/weather.json")

    /// Used until places are chosen on the phone.
    static let defaults = [
        Place(name: "Vijayawada, AP", lat: 16.5062, lon: 80.6480),
        Place(name: "Little Elm, TX", lat: 33.1626, lon: -96.9375),
        Place(name: "Bentonville, AR", lat: 36.3729, lon: -94.2088),
        Place(name: "Seattle, WA", lat: 47.6062, lon: -122.3321),
    ]

    private let lock = NSLock()
    private var places: [Place]
    private var current: [[String: Any]] = []
    private var timer: DispatchSourceTimer?

    init() { places = Weather.load() ?? Weather.defaults }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 1, repeating: 15 * 60)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return current }

    // MARK: The list of places (saved in ~/.oldphonedeck/weather.json)

    func placeList() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return places.map { ["name": $0.name, "lat": $0.lat, "lon": $0.lon] }
    }

    /// json: [{"name": …, "lat": …, "lon": …}, …] in display order. Returns how many were saved.
    @discardableResult
    func save(json: String) throws -> Int {
        let raw = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        let list = raw.compactMap { d -> Place? in
            guard let name = d["name"] as? String, !name.isEmpty,
                  let lat = (d["lat"] as? NSNumber)?.doubleValue, let lon = (d["lon"] as? NSNumber)?.doubleValue,
                  abs(lat) <= 90, abs(lon) <= 180 else { return nil }
            return Place(name: String(name.prefix(40)), lat: lat, lon: lon)
        }.prefix(Weather.maxPlaces)
        let out = list.map { ["name": $0.name, "lat": $0.lat, "lon": $0.lon] }
        try FileManager.default.createDirectory(at: Weather.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: .prettyPrinted).write(to: Weather.file)
        lock.lock(); places = Array(list); current = []; lock.unlock()
        DispatchQueue.global().async { [weak self] in self?.refresh() }
        return list.count
    }

    private static func load() -> [Place]? {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let list = raw.compactMap { d -> Place? in
            guard let name = d["name"] as? String, let lat = (d["lat"] as? NSNumber)?.doubleValue,
                  let lon = (d["lon"] as? NSNumber)?.doubleValue else { return nil }
            return Place(name: name, lat: lat, lon: lon)
        }
        return list.isEmpty ? nil : list
    }

    // MARK: City search (Open-Meteo geocoding)

    /// "Little Elm, TX" searches for "Little Elm" and puts matches in Texas/"TX" first.
    func search(_ text: String, done: @escaping ([[String: Any]]) -> Void) {
        let parts = text.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, name.count >= 2 else { return done([]) }
        let hint = parts.count > 1 ? parts[1].lowercased() : ""
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "10"),
                        URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        guard let url = c.url else { return done([]) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            var results: [[String: Any]] = []
            for r in (json?["results"] as? [[String: Any]]) ?? [] {
                guard let city = r["name"] as? String, let lat = (r["latitude"] as? NSNumber)?.doubleValue,
                      let lon = (r["longitude"] as? NSNumber)?.doubleValue else { continue }
                let region = (r["admin1"] as? String) ?? ""
                let country = (r["country"] as? String) ?? ""
                let code = (r["country_code"] as? String) ?? ""
                let detail = region.isEmpty ? "" : country   // the name already has the region
                let short = region.isEmpty ? (country.isEmpty ? city : "\(city), \(country)") : "\(city), \(region)"
                let matches = hint.isEmpty || [region, country, code, Weather.stateCode(region)]
                    .contains { !$0.isEmpty && $0.lowercased().hasPrefix(hint) }
                results.append(["name": short, "detail": detail, "lat": lat, "lon": lon, "match": matches])
            }
            // Matches for the part after the comma first; keep the rest in case the hint was off.
            let hits = results.filter { $0["match"] as? Bool == true }
            done(hits + results.filter { $0["match"] as? Bool != true })
        }.resume()
    }

    /// "Texas" → "TX", so a search like "Little Elm, TX" ranks the right town first.
    private static func stateCode(_ state: String) -> String {
        let codes = ["Alabama": "AL", "Alaska": "AK", "Arizona": "AZ", "Arkansas": "AR", "California": "CA", "Colorado": "CO",
                     "Connecticut": "CT", "Delaware": "DE", "Florida": "FL", "Georgia": "GA", "Hawaii": "HI", "Idaho": "ID",
                     "Illinois": "IL", "Indiana": "IN", "Iowa": "IA", "Kansas": "KS", "Kentucky": "KY", "Louisiana": "LA",
                     "Maine": "ME", "Maryland": "MD", "Massachusetts": "MA", "Michigan": "MI", "Minnesota": "MN",
                     "Mississippi": "MS", "Missouri": "MO", "Montana": "MT", "Nebraska": "NE", "Nevada": "NV",
                     "New Hampshire": "NH", "New Jersey": "NJ", "New Mexico": "NM", "New York": "NY", "North Carolina": "NC",
                     "North Dakota": "ND", "Ohio": "OH", "Oklahoma": "OK", "Oregon": "OR", "Pennsylvania": "PA",
                     "Rhode Island": "RI", "South Carolina": "SC", "South Dakota": "SD", "Tennessee": "TN", "Texas": "TX",
                     "Utah": "UT", "Vermont": "VT", "Virginia": "VA", "Washington": "WA", "West Virginia": "WV",
                     "Wisconsin": "WI", "Wyoming": "WY", "Andhra Pradesh": "AP", "Telangana": "TS"]
        return codes[state] ?? ""
    }

    // MARK: Current conditions

    private func refresh() {
        lock.lock(); let places = self.places; lock.unlock()
        guard !places.isEmpty else { return }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: places.map { String($0.lat) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: places.map { String($0.lon) }.joined(separator: ",")),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = c.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            // Several places → a JSON array; a single place → one object.
            let results = (json as? [[String: Any]]) ?? ((json as? [String: Any]).map { [$0] } ?? [])
            var out: [[String: Any]] = []
            for (i, r) in results.enumerated() where i < places.count {
                guard let cur = r["current"] as? [String: Any], let temp = (cur["temperature_2m"] as? NSNumber)?.doubleValue else { continue }
                out.append([
                    "name": places[i].name,
                    "temp": temp,
                    "code": (cur["weather_code"] as? NSNumber)?.intValue ?? 0,
                    "day": ((cur["is_day"] as? NSNumber)?.intValue ?? 1) == 1,
                    "offset": (r["utc_offset_seconds"] as? NSNumber)?.intValue ?? 0,   // for the city's local time
                ])
            }
            if out.isEmpty {
                // No network yet (e.g. right after waking): try again in a minute.
                DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in self?.refresh() }
                return
            }
            self.lock.lock()
            if self.places.map({ $0.name }) == places.map({ $0.name }) { self.current = out }   // ignore a stale reply
            self.lock.unlock()
        }.resume()
    }
}
