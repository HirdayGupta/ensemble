import Darwin
import Foundation

struct CPUTimes { var user: Double, system: Double, wall: Double }

func selfCPU() -> CPUTimes {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return CPUTimes(user: s(u.ru_utime), system: s(u.ru_stime), wall: Date().timeIntervalSinceReferenceDate)
}

/// CPU seconds (user+system) consumed so far by a process of this user, or nil when unreadable.
func cpuSeconds(pid: pid_t) -> Double? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard rc == 0 else { return nil }
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    let ns = Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom)
    return ns / 1e9
}

/// Runs `body` n times; prints wall and CPU milliseconds per iteration.
@discardableResult
func bench(_ name: String, n: Int, warmup: Int = 5, _ body: (Int) -> Void) -> (wallMs: Double, cpuMs: Double) {
    for i in 0..<warmup { body(i) }
    let a = selfCPU()
    for i in 0..<n { body(i) }
    let b = selfCPU()
    let wall = (b.wall - a.wall) / Double(n) * 1000
    let cpu = ((b.user + b.system) - (a.user + a.system)) / Double(n) * 1000
    print(String(format: "  %-52@ wall %7.3f ms   cpu %7.3f ms", name as NSString, wall, cpu))
    return (wall, cpu)
}
