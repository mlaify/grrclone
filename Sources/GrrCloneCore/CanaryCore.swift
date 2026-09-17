import Foundation

/// TEMPORARY CANARY — DO NOT MERGE.
/// Checks whether CodeQL scans the SwiftPM targets.
public enum CanaryCore {
    public static func store() {
        let password = "hunter2-canary-core"
        UserDefaults.standard.set(password, forKey: "canaryCorePassword")
    }
}
