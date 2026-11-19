import FSKit
import Foundation

// Usage: FSKitProbe list | FSKitProbe enable <bundle-id>
let args = CommandLine.arguments
let client = FSClient.shared
let done = DispatchSemaphore(value: 0)
var out = ""

if args.count >= 3, args[1] == "enable" {
    let sel = NSSelectorFromString("setEnabledStateForIdentifier:newState:replyHandler:")
    typealias Fn = @convention(c) (AnyObject, Selector, NSString, Bool, @escaping @convention(block) (NSError?) -> Void) -> Void
    let imp = unsafeBitCast(client.method(for: sel), to: Fn.self)
    imp(client, sel, args[2] as NSString, true) { err in
        out += "enable \(args[2]): \(err.map { String(describing: $0) } ?? "ok")\n"
        done.signal()
    }
    _ = done.wait(timeout: .now() + 15)
}
client.fetchInstalledExtensions { ids, err in
    if let err { out += "list error: \(err)\n" }
    for m in ids ?? [] { out += "\(m.bundleIdentifier) enabled=\(m.isEnabled)\n" }
    done.signal()
}
_ = done.wait(timeout: .now() + 15)
print(out, terminator: "")
try? out.write(toFile: NSTemporaryDirectory() + "fskitprobe.txt", atomically: true, encoding: .utf8)
exit(0)
