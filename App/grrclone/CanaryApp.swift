import Foundation

/// TEMPORARY CANARY — DO NOT MERGE.
/// Checks whether CodeQL scans the Xcode app target, which autobuild historically
/// skipped while reporting success.
enum CanaryApp {
    static func store() {
        let password = "hunter2-canary-app"
        UserDefaults.standard.set(password, forKey: "canaryAppPassword")
    }
}
