import Foundation

enum EnsembleResources {
    /// The SwiftPM resource bundle. In the packaged app it sits in Contents/Resources; `Bundle.module` only
    /// finds it there through a build-machine path, so it is a fallback for `swift run` and tests.
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Ensemble_Ensemble.bundle"), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
