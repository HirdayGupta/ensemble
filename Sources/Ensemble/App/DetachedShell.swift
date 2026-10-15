import Foundation

/// Runs a short /bin/sh script in its own session, so it outlives Ensemble. A child started with `Process` shares
/// Ensemble's process group, and when Ensemble runs as the login agent's job, launchd kills that whole group as the
/// job exits, which would take the script that is meant to open Ensemble again down with it.
enum DetachedShell {
    /// Opens Ensemble again: launchd's job when open at login is on (so crash restarts keep working), the bundle otherwise.
    static let reopen = """
    reopen() { if [ "$3" = 1 ]; then /bin/launchctl kickstart "gui/$4/$5" 2>/dev/null && return; fi; /usr/bin/open "$2"; }
    """

    /// The arguments every script here reads: $1 this process, $2 the bundle, $3 open at login on, $4 uid, $5 job label.
    static var standardArguments: [String] {
        [String(getpid()), Bundle.main.bundlePath, LoginAgent.isEnabled ? "1" : "0", String(getuid()), LoginAgent.label]
    }

    @discardableResult
    static func run(_ script: String, arguments: [String] = standardArguments) -> Bool {
        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let argv = ["/bin/sh", "-c", reopen + "\n" + script, "sh"] + arguments
        var cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", nil, &attr, &cArgs, environ)
        if status != 0 { EnsembleLog.write("detached shell did not start (errno \(status))") }
        return status == 0
    }
}
