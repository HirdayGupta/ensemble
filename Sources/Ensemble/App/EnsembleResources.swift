import Foundation

enum EnsembleResources {
    /// The face tracker's web folder, copied into Contents/Resources by scripts/bundle.sh. Ensemble runs only as a
    /// bundled app: the folder is deliberately not a SwiftPM resource (see Package.swift).
    static let web: URL? = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true)
}
