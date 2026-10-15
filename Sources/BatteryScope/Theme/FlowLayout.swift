import SwiftUI

/// Lays its children out left to right and wraps to a new line when the current one is full.
///
/// Used for the chart tab's metric chips. They used to sit in a plain `HStack`, which cannot wrap:
/// with ten metrics on a 960 pt window the row ran out of space, so the chips were compressed and
/// their labels were truncated to "电池…", "整机…", "CPU…" — the labels that identify what the
/// charts below are showing.
///
/// `LazyVGrid` with adaptive columns would also wrap, but it gives every cell the same width, which
/// stretches short labels like "电量" across as much space as "适配器供电". A flow layout keeps each
/// child at its natural size.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeights: [CGFloat] = [0]
        var widest: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                widest = Swift.max(widest, x)
                x = 0
                rowHeights.append(0)
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeights[rowHeights.count - 1] = Swift.max(rowHeights[rowHeights.count - 1], size.height)
        }
        widest = Swift.max(widest, x)

        let height = rowHeights.reduce(0, +) + lineSpacing * CGFloat(Swift.max(0, rowHeights.count - 1))
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = Swift.max(lineHeight, size.height)
        }
    }
}
