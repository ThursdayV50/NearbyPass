// mem.swift — 读进程内存。phys_footprint 才是活动监视器显示的那个数字。
// 用法: mem <pid>
import Foundation
import Darwin

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    print("用法: mem <pid>")
    exit(1)
}

// phys_footprint（≈ 活动监视器「内存」）
var info = rusage_info_v4()
let ok = withUnsafeMutablePointer(to: &info) { p -> Int32 in
    p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { q in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, q)
    }
}
if ok == 0 {
    let footprint = Double(info.ri_phys_footprint) / 1024 / 1024
    let resident = Double(info.ri_resident_size) / 1024 / 1024
    let lifetime = Double(info.ri_lifetime_max_phys_footprint) / 1024 / 1024
    print(String(format: "phys_footprint %.1f MB   resident %.1f MB   峰值 %.1f MB",
                 footprint, resident, lifetime))
} else {
    print("proc_pid_rusage 失败: \(ok)")
}

// 任务信息（线程数 / 虚拟大小）
var ti = proc_taskinfo()
let sz = Int32(MemoryLayout<proc_taskinfo>.size)
let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sz)
if r == sz {
    print("线程 \(ti.pti_threadnum)   虚拟 \(Double(ti.pti_virtual_size) / 1024 / 1024 / 1024) GB")
}
