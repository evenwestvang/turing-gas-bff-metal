/// Opt-in per-frame host-stage timing for the interactive app's render loop, mirroring
/// the headless benchmark's `HostStageAttribution` but scoped to the app-only stages the
/// benchmark cannot see: the bounded epoch batch, snapshot creation, aggregate
/// metric-texture population/upload, and render encode/submit.
///
/// This model is **pure and platform-independent** — no Metal, no clock of its own — so
/// the reconciliation math (per-stage means, the explicit unclassified remainder, and
/// the "available only when present on every frame" rule) is unit-tested on any host.
/// The macOS shell (`AppModel`/`Renderer`) feeds it real spans where each is technically
/// measurable; the Metal-only stages (`metricTexture`, `renderSubmit`) stay `nil` on a
/// host that never encoded a frame, exactly as the benchmark's evaluator substages stay
/// `nil` off-Metal — never a fabricated number.
///
/// Reconciliation invariant (checked by tests): the available stage means plus
/// `unclassifiedMsPerFrame` equal the mean frame wall (ms/frame). A stage is "available"
/// only if it was recorded on *every* folded frame; otherwise its mean is `nil` and its
/// time falls into the remainder, so the sum always reconciles.

// MARK: - One frame's measured spans

/// The optional host-stage spans for ONE app frame, in seconds. `frameSeconds` is the
/// frame wall these decompose; any `nil` stage was not measured on this frame.
public struct AppFrameStageSample: Equatable, Sendable {
    /// The whole frame wall (advance + snapshot + texture + encode/submit + slack).
    public var frameSeconds: Double
    /// Bounded epoch batch (`AppModel.stepFrame`'s `runEpoch` loop).
    public var epochBatchSeconds: Double?
    /// `RenderSnapshot.build` — immutable snapshot creation from the committed soup.
    public var snapshotBuildSeconds: Double?
    /// Aggregate metric-texture population + `replace`/upload (Metal only).
    public var metricTextureSeconds: Double?
    /// Render command encode + `commit` submit (Metal only).
    public var renderSubmitSeconds: Double?

    public init(frameSeconds: Double, epochBatchSeconds: Double? = nil,
                snapshotBuildSeconds: Double? = nil, metricTextureSeconds: Double? = nil,
                renderSubmitSeconds: Double? = nil) {
        self.frameSeconds = frameSeconds
        self.epochBatchSeconds = epochBatchSeconds
        self.snapshotBuildSeconds = snapshotBuildSeconds
        self.metricTextureSeconds = metricTextureSeconds
        self.renderSubmitSeconds = renderSubmitSeconds
    }
}

// MARK: - Aggregated attribution

/// The folded, reconciled app-frame attribution: per-stage mean ms/frame plus the
/// explicit unclassified remainder, over the recorded frames. All optional stage means
/// are `nil` unless the stage was present on every recorded frame.
public struct AppFrameStageAttribution: Equatable, Sendable {
    public var frameCount: Int
    public var meanFrameMs: Double
    public var epochBatchMsPerFrame: Double?
    public var snapshotBuildMsPerFrame: Double?
    public var metricTextureMsPerFrame: Double?
    public var renderSubmitMsPerFrame: Double?
    /// The named unclassified/remainder component: mean(frame wall − Σ available stages)
    /// ms/frame. Non-negative by construction.
    public var unclassifiedMsPerFrame: Double
    /// Fraction of the frame wall explained by the available named stages, `[0, 1]`.
    public var classifiedFrameFraction: Double

    /// A compact, deterministic one-line summary for the validation diagnostic. Stages
    /// that were not measured are printed as `null` so the field set is stable.
    public var summaryLine: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "null" }
        return "frames=\(frameCount) "
            + String(format: "meanFrameMs=%.4f ", meanFrameMs)
            + "epochBatchMs=\(f(epochBatchMsPerFrame)) "
            + "snapshotMs=\(f(snapshotBuildMsPerFrame)) "
            + "metricTextureMs=\(f(metricTextureMsPerFrame)) "
            + "renderSubmitMs=\(f(renderSubmitMsPerFrame)) "
            + String(format: "unclassifiedMs=%.4f ", unclassifiedMsPerFrame)
            + String(format: "classifiedFrac=%.4f", classifiedFrameFraction)
    }
}

// MARK: - Accumulator

/// Folds `AppFrameStageSample`s into an `AppFrameStageAttribution`. Pure value type:
/// `record` sums, `summary()` reconciles. Kept separate from the Metal shell so its
/// behavior is fully testable.
public struct AppFrameStageAccumulator: Equatable, Sendable {
    private var frames = 0
    private var wallSum = 0.0
    private var epochSum = 0.0, epochCount = 0
    private var snapshotSum = 0.0, snapshotCount = 0
    private var textureSum = 0.0, textureCount = 0
    private var submitSum = 0.0, submitCount = 0

    public init() {}

    /// Fold one frame. A `nil` stage simply isn't counted for that frame; a stage's mean
    /// is reported only when it was present on *every* folded frame.
    public mutating func record(_ s: AppFrameStageSample) {
        frames += 1
        wallSum += s.frameSeconds
        if let v = s.epochBatchSeconds { epochSum += v; epochCount += 1 }
        if let v = s.snapshotBuildSeconds { snapshotSum += v; snapshotCount += 1 }
        if let v = s.metricTextureSeconds { textureSum += v; textureCount += 1 }
        if let v = s.renderSubmitSeconds { submitSum += v; submitCount += 1 }
    }

    /// Number of frames folded so far.
    public var frameCount: Int { frames }

    /// Reconcile into an attribution, or `nil` if no frame was recorded.
    public func summary() -> AppFrameStageAttribution? {
        guard frames > 0 else { return nil }
        let n = Double(frames)
        let ms = 1000.0 / n

        // A stage mean is available only when present on every frame; its full sum then
        // contributes to the classified total. A partially-present stage is reported as
        // `nil` and its (undercounted) time is left in the remainder, so the sum always
        // reconciles to the frame wall.
        func mean(_ sum: Double, _ count: Int) -> Double? {
            count == frames ? sum * ms : nil
        }
        let epoch = mean(epochSum, epochCount)
        let snapshot = mean(snapshotSum, snapshotCount)
        let texture = mean(textureSum, textureCount)
        let submit = mean(submitSum, submitCount)

        var classifiedSum = 0.0
        if epochCount == frames { classifiedSum += epochSum }
        if snapshotCount == frames { classifiedSum += snapshotSum }
        if textureCount == frames { classifiedSum += textureSum }
        if submitCount == frames { classifiedSum += submitSum }

        let unclassified = Swift.max(0, wallSum - classifiedSum)
        let fraction = wallSum > 0 ? classifiedSum / wallSum : 0

        return AppFrameStageAttribution(
            frameCount: frames,
            meanFrameMs: wallSum * ms,
            epochBatchMsPerFrame: epoch,
            snapshotBuildMsPerFrame: snapshot,
            metricTextureMsPerFrame: texture,
            renderSubmitMsPerFrame: submit,
            unclassifiedMsPerFrame: unclassified * ms,
            classifiedFrameFraction: fraction)
    }
}
