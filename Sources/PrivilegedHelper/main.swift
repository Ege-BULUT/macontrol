import Darwin
import Foundation
import Safety

// macontrol-priv <folder>/request.json <sha256>: run as root through the administrator dialog for one request
// (DESIGN-debloat section 3.3). Argv parsing and the detach only; the checks and the work are Safety.PrivilegedExecutor.

// Swift marks fork() unavailable. The helper forks once and never execs: the child keeps the checked request in memory.
@_silgen_name("fork") private func detach() -> pid_t

// Nothing inherited from the shell reaches launchctl or anything else this process does.
for key in ProcessInfo.processInfo.environment.keys { unsetenv(key) }

var arguments = Array(CommandLine.arguments.dropFirst())
var executor = PrivilegedExecutor(launchctl: LaunchdSystem.run)

#if DEBUG
// Tests run the debug helper as themselves: --test-root <system root> --test-home <home> [--test-hold <file> <index>]
// waits before item <index> until <file> exists. Not root and no test root: refused, so it never acts on this Mac.
if let flag = arguments.firstIndex(of: "--test-root"), arguments.count >= flag + 4, arguments[flag + 2] == "--test-home" {
    let root = arguments[flag + 1]
    let home = arguments[flag + 3]
    var hold: (file: String, index: Int)?
    if arguments.count >= flag + 7, arguments[flag + 4] == "--test-hold", let index = Int(arguments[flag + 6]) {
        hold = (arguments[flag + 5], index)
    }
    arguments.removeSubrange(flag...)
    executor = PrivilegedExecutor(testRoot: root, home: home, launchctl: LaunchdSystem.run, beforeItem: { [hold] index in
        guard let hold, hold.index == index else { return }
        for _ in 0..<600 where access(hold.file, F_OK) != 0 { usleep(50_000) }
    })
}
#endif

guard arguments.count == 2 else { exit(PrivilegedExit.malformed.rawValue) }
let checked: PrivilegedExecutor.Checked
switch executor.check(requestPath: arguments[0], sha256: arguments[1]) {
case .success(let request): checked = request
case .failure(let exit): Darwin.exit(exit.rawValue)
}

// A fork is safe only while this process has never had a second thread; if the check started one, refuse.
guard pthread_is_threaded_np() == 0 else { exit(PrivilegedExit.systemError.rawValue) }
let child = detach()
guard child >= 0 else { exit(PrivilegedExit.systemError.rawValue) }
// The parent returns at once, so the administrator dialog's `do shell script` returns and the app polls the results.
guard child == 0 else { exit(0) }

_ = setsid()
let null = open("/dev/null", O_RDWR)
for descriptor: Int32 in 0...2 { dup2(null, descriptor) }
executor.run(checked)
exit(0)
