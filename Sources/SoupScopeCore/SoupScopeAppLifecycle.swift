import Foundation

/// The SwiftUI scene shape SoupScope composes for a launch plan.
public enum SoupScopeSceneComposition: Equatable, Sendable {
    case sharedWindowGroup(id: String)

    public var windowSceneID: String {
        switch self {
        case let .sharedWindowGroup(id):
            return id
        }
    }
}

/// The initial snapshot source the app shell seeds `lastSnapshot` from at
/// launch, derived from the launch plan. The non-resident path builds the
/// epoch-0 `RenderSnapshot.initial` from the constructed legacy CPU runner's
/// seeded soup; the resident path skips that build (its soup lives on the GPU)
/// and leaves `lastSnapshot` `nil` until the resident driver produces a frame.
public enum InitialSnapshotSource: Equatable, Sendable {
    case legacyCPURunner
    case none
}

/// Portable lifecycle invariants for the SoupScope macOS shell.
///
/// These are pure values (no AppKit/SwiftUI dependency) so the app's
/// lifecycle/configuration contract is testable on Linux, exactly like the
/// other pure models in this module. The SwiftUI shell consumes these
/// constants so the shell and the tests share one source of truth.
public enum SoupScopeAppLifecycle {
    /// The shared `WindowGroup` scene identifier the SwiftUI shell uses.
    ///
    /// SoupScope is a single-window app rendered through one automatically
    /// presented shared `WindowGroup`: SwiftUI presents the one main window at
    /// launch with no explicit `openWindow`/AppKit `NSWindow` wiring. The id is
    /// constant and tested so the shell cannot drift from the contract.
    public static let windowSceneID = "dev.bff.soupscope.window"

    /// The production SwiftUI scene composition for every launch plan. Both
    /// resident and non-resident launches share the same automatically
    /// presented `WindowGroup` plan; routing differences live in
    /// `constructsLegacyCPURunner`/`initialSnapshotSource`, not the scene.
    public static func sceneComposition(for plan: ResidentAppRunPlan) -> SoupScopeSceneComposition {
        _ = plan
        return .sharedWindowGroup(id: windowSceneID)
    }

    /// True iff the legacy CPU `SoupRunner` should be constructed for this plan.
    public static func constructsLegacyCPURunner(for plan: ResidentAppRunPlan) -> Bool {
        !plan.enabled
    }

    /// The initial snapshot source for this plan: non-resident mode seeds
    /// `lastSnapshot` from the legacy CPU runner's soup; resident mode seeds
    /// nothing (its soup lives on the GPU). Derived from the same
    /// `constructsLegacyCPURunner` invariant so the shell and tests share one
    /// source of truth.
    public static func initialSnapshotSource(for plan: ResidentAppRunPlan) -> InitialSnapshotSource {
        constructsLegacyCPURunner(for: plan) ? .legacyCPURunner : .none
    }
}
