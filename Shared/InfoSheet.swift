import SwiftUI
import MapKit
import CoreLocation

/// Info zu einem Eintrag (wie MacJournal „Inspector“): Merkmale ändern, Ort mit Karte, Wörter.
struct InfoSheet: View {
    @EnvironmentObject private var library: Library
    let url: URL
    let done: () -> Void

    @State private var values: [MetaKey: String] = [:]
    @State private var rating = 0
    @State private var placeText = ""
    @State private var searching = false
    @State private var message: String?
    @StateObject private var locator = Locator()

    var body: some View {
        let entry = library.entries.first { $0.url == url }
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(entry?.title ?? url.lastPathComponent).font(.headline)
                    if let entry {
                        Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    let words = Library.wordCount(library.read(url))
                    Text("\(words) Wörter").foregroundStyle(.secondary)
                }
                Section("Merkmale") {
                    LabeledContent("Bewertung") { StarRating(value: $rating, size: 18) }
                    Picker("Etikett", selection: binding(.etikett)) {
                        Text("keines").tag("")
                        ForEach(MetaKey.labelColors, id: \.name) { item in
                            Label { Text(item.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(item.color) }
                                .tag(item.name)
                        }
                    }
                    choicePicker(.stimmung)
                    choicePicker(.status)
                    choicePicker(.prioritaet)
                }
                Section("Ort") {
                    TextField("Ort", text: $placeText, prompt: Text("z. B. Lübeck, Breite Straße"))
                        .onSubmit(findPlace)
                    HStack {
                        Button("Ort suchen", action: findPlace)
                            .disabled(placeText.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                        Button("Aktueller Ort", action: useCurrentLocation)
                            .disabled(searching)
                        if !(values[.geo] ?? "").isEmpty {
                            Button("Ort entfernen", role: .destructive) {
                                placeText = ""
                                values[.geo] = ""
                            }
                        }
                        if searching { ProgressView().controlSize(.small) }
                    }
                    if let coordinate = coordinate {
                        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                            Marker(placeText.isEmpty ? "Ort" : placeText, coordinate: coordinate)
                        }
                        .frame(height: 180)
                        .id("\(coordinate.latitude),\(coordinate.longitude)")
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Sichern", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 460, height: 640)
        #endif
        .onAppear {
            let meta = entry?.meta ?? [:]
            for key in MetaKey.allCases { values[key] = meta[key.rawValue] ?? "" }
            rating = entry?.rating ?? 0
            placeText = meta[MetaKey.ort.rawValue] ?? ""
        }
    }

    private var coordinate: CLLocationCoordinate2D? {
        let parts = (values[.geo] ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 2 ? CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]) : nil
    }

    private func binding(_ key: MetaKey) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func choicePicker(_ key: MetaKey) -> some View {
        Picker(key.label, selection: binding(key)) {
            Text("–").tag("")
            ForEach(key.choices, id: \.self) { Text($0).tag($0) }
        }
    }

    private static func geoString(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    /// Ortsnamen in Koordinaten umwandeln.
    private func findPlace() {
        let text = placeText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        message = nil
        CLGeocoder().geocodeAddressString(text) { marks, _ in
            DispatchQueue.main.async {
                searching = false
                guard let location = marks?.first?.location else {
                    message = "Ort nicht gefunden."
                    return
                }
                values[.geo] = Self.geoString(location.coordinate)
            }
        }
    }

    /// Wo bin ich? Koordinaten und ein lesbarer Name.
    private func useCurrentLocation() {
        searching = true
        message = nil
        locator.request { location in
            guard let location else {
                searching = false
                message = "Der aktuelle Ort ist nicht verfügbar. Ortungsdienste in den Systemeinstellungen erlauben."
                return
            }
            values[.geo] = Self.geoString(location.coordinate)
            CLGeocoder().reverseGeocodeLocation(location) { marks, _ in
                DispatchQueue.main.async {
                    searching = false
                    if let mark = marks?.first {
                        placeText = [mark.thoroughfare, mark.locality].compactMap { $0 }.joined(separator: ", ")
                    }
                }
            }
        }
    }

    private func save() {
        values[.bewertung] = rating > 0 ? String(rating) : ""
        values[.ort] = placeText
        let entry = library.entries.first { $0.url == url }
        var changes: [MetaKey: String?] = [:]
        for key in MetaKey.allCases {
            let new = values[key] ?? ""
            let old = entry?.meta[key.rawValue] ?? ""
            if new != old { changes[key] = new.isEmpty ? nil : new }
        }
        do {
            try library.setMeta(url, changes)
            done()
        } catch {
            message = "Sichern ging nicht: \(error.localizedDescription)"
        }
    }
}

/// Einmal den aktuellen Ort holen.
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var done: ((CLLocation?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request(_ done: @escaping (CLLocation?) -> Void) {
        self.done = done
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(nil)
        default: manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard done != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(nil)
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { finish(locations.last) }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }

    private func finish(_ location: CLLocation?) {
        let callback = done
        done = nil
        DispatchQueue.main.async { callback?(location) }
    }
}
