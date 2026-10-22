/// One entry of the camera choice shown in the menu panel and in Settings.
public struct CameraChoice: Equatable {
    /// What is stored when this entry is picked: nil is Automatic.
    public let name: String?
    public let isCurrent: Bool
    /// False only for a chosen camera that is not plugged in; Automatic always counts as connected.
    public let isConnected: Bool

    public var title: String { name ?? "Automatic" }
    /// Title plus the reason it cannot be used right now, if any.
    public var label: String { isConnected ? title : "\(title) (not connected)" }
}

public enum CameraKind: Equatable, Sendable { case external, builtIn, continuity, other }

public enum CameraChoices {
    /// The index Automatic starts. A Continuity Camera (an iPhone near the Mac) is started only when no other camera
    /// is connected, even with a saved calibration: the phone joins and leaves on its own, and Automatic took it
    /// over the Mac's own camera with no hint why. Choosing it by name still works. Among the rest, a camera with a
    /// saved calibration wins over one without; within each group an external camera beats the built-in one, which
    /// beats any other, and ties keep the connection order.
    public static func automaticPick(_ cameras: [(id: String, kind: CameraKind)], calibratedIDs: Set<String>) -> Int? {
        func rank(_ kind: CameraKind) -> Int { kind == .external ? 0 : kind == .builtIn ? 1 : 2 }
        return cameras.indices.min { a, b in
            let (pa, pb) = (cameras[a].kind == .continuity, cameras[b].kind == .continuity)
            if pa != pb { return pb }
            let (ca, cb) = (calibratedIDs.contains(cameras[a].id), calibratedIDs.contains(cameras[b].id))
            if ca != cb { return ca }
            let (ra, rb) = (rank(cameras[a].kind), rank(cameras[b].kind))
            return ra != rb ? ra < rb : a < b
        }
    }

    /// Automatic first, then each connected camera in the order given. A chosen camera that is not connected is kept
    /// at the end so the setting never reads as something else, and is flagged as not connected.
    public static func rows(connected: [String], chosen: String?) -> [CameraChoice] {
        var rows = [CameraChoice(name: nil, isCurrent: chosen == nil, isConnected: true)]
        rows += connected.map { CameraChoice(name: $0, isCurrent: $0 == chosen, isConnected: true) }
        if let chosen, !connected.contains(chosen) {
            rows.append(CameraChoice(name: chosen, isCurrent: true, isConnected: false))
        }
        return rows
    }
}
