import BFFOracle

/// Static facts about this scaffold build, displayed by the app's placeholder window.
/// Lives in a platform-independent module so the app's wiring is testable on Linux.
public enum ScaffoldInfo {
    public static let appName = "SoupScope"

    /// Proves the app's dependency chain reaches the CPU oracle.
    public static var oracleWiring: String {
        "BFFOracle linked: \(BFF.tapeSize)-byte programs, \(BFF.stepBudget)-step budget"
    }
}
