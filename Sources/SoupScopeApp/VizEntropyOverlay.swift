#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import SoupScopeCore

/// Compact bounded entropy-over-time overlay for the resident visualization path.
/// The state is explicit:
///
/// - unavailable: no real viz entropy source is connected; show this visibly.
/// - waiting: a real source is available, but no sample has arrived yet.
/// - data: one or more bounded history samples are present.
///
/// The values are visualization-grade only and stay separate from Brotli /
/// scientific entropy cadence.
struct VizEntropyOverlay: View {
    let history: VizEntropyHistory
    let available: Bool
    let channel: ResidentVizChannel

    fileprivate static let panelBackground = Color(
        red: 0.965, green: 0.955, blue: 0.935, opacity: 0.92)
    fileprivate static let charcoal = Color(red: 0.20, green: 0.18, blue: 0.16)
    private static let charcoalSecondary = Color(red: 0.38, green: 0.34, blue: 0.30)
    private static let dataLine = Color(red: 0.22, green: 0.40, blue: 0.62)
    private static let gridRule = Color(red: 0.78, green: 0.74, blue: 0.68, opacity: 0.55)
    private static let unavailableColor = Color(red: 0.62, green: 0.22, blue: 0.18)

    private static let plotWidth: CGFloat = 220
    private static let plotHeight: CGFloat = 48
    fileprivate static let sidePadding: CGFloat = 10

    var body: some View {
        if !available {
            unavailablePanel
        } else if history.isEmpty {
            waitingPanel
        } else {
            dataPanel
        }
    }

    private var unavailablePanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            Text("viz entropy unavailable")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Self.unavailableColor)
            Text("resident entropy source not connected")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Self.charcoalSecondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, Self.sidePadding)
        .frame(width: Self.plotWidth + 2 * Self.sidePadding)
        .background(Self.panelBackground)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Self.unavailableColor.opacity(0.6), lineWidth: 0.5))
        .padding(10)
    }

    private var waitingPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            plotFrame
            Text("waiting for first epoch...")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Self.charcoalSecondary)
                .frame(width: Self.plotWidth, alignment: .center)
        }
        .panelChrome()
    }

    private var dataPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            plotFrame
            footer
        }
        .panelChrome()
    }

    private var title: some View {
        Text("Mean byte entropy - viz approx")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(Self.charcoal)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            title
            Text("history: mean byte entropy   |   bits/byte")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Self.charcoalSecondary)
        }
    }

    private var plotFrame: some View {
        ZStack {
            ForEach(0..<3) { i in
                let y = Self.plotHeight * CGFloat(i) / 2.0
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: Self.plotWidth, y: y))
                }
                .stroke(Self.gridRule, lineWidth: 0.5)
            }
            sparkline
        }
        .frame(width: Self.plotWidth, height: Self.plotHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var sparkline: some View {
        let samples = history.allSamples
        if !samples.isEmpty {
            let n = samples.count
            let dx = n > 1 ? Self.plotWidth / CGFloat(n - 1) : 0.0
            let yScale = Self.plotHeight / 6.0
            Path { path in
                var hasOpenSegment = false
                for (index, sample) in samples.enumerated() {
                    guard let point = point(for: sample,
                                            index: index,
                                            dx: dx,
                                            yScale: yScale) else {
                        hasOpenSegment = false
                        continue
                    }
                    if hasOpenSegment {
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                        hasOpenSegment = true
                    }
                }
            }
            .stroke(Self.dataLine, lineWidth: 1.0)
        }
    }

    private func point(for sample: VizEntropySample,
                       index: Int,
                       dx: CGFloat,
                       yScale: CGFloat) -> CGPoint? {
        guard sample.meanByteEntropyBitsPerByte.isFinite else { return nil }
        let x = dx * CGFloat(index)
        let clamped = min(max(sample.meanByteEntropyBitsPerByte, 0), 6)
        let y = Self.plotHeight - CGFloat(clamped) * yScale
        return CGPoint(x: x, y: y)
    }

    private var footer: some View {
        let samples = history.allSamples
        let earliest = samples.first?.epoch ?? 0
        let latest = samples.last?.epoch ?? 0
        let latestValue = samples.last?.meanByteEntropyBitsPerByte ?? 0
        return HStack(spacing: 8) {
            Text("y: 0-6 bits/byte")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Self.charcoalSecondary)
            Spacer()
            Text("epoch \(earliest)-\(latest)   |   "
                 + String(format: "now %.3f", latestValue))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Self.charcoalSecondary)
        }
        .frame(width: Self.plotWidth)
    }
}

private extension View {
    func panelChrome() -> some View {
        padding(.vertical, 8)
            .padding(.horizontal, VizEntropyOverlay.sidePadding)
            .background(VizEntropyOverlay.panelBackground)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(VizEntropyOverlay.charcoal.opacity(0.35), lineWidth: 0.5))
            .padding(10)
    }
}
#endif
