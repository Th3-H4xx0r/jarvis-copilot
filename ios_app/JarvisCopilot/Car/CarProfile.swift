import Foundation

/// The car itself. One car for now — his — so the profile is a constant.
struct CarProfile: Equatable {
    let year: Int
    let make: String
    let model: String
    let trim: String
    let colorName: String
    /// The maker's paint code.
    let colorCode: String

    static let camry = CarProfile(year: 2026, make: "Toyota", model: "Camry", trim: "SE",
                                  colorName: "Dark Cosmos", colorCode: "8Z3")

    /// "2026 Toyota Camry SE".
    var description: String { "\(year) \(make) \(model) \(trim)" }

    var json: [String: Any] {
        ["year": year, "make": make, "model": model, "trim": trim, "color": colorName, "color_code": colorCode]
    }
}
