import SwiftUI

/// Lays views out left to right, wrapping to the next line when the width
/// runs out — chips beside a text field, and the field itself as the last
/// item on whatever line is left.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews: subviews, within: width)

        let height = lines.reduce(into: 0.0) { total, line in
            total += line.height
        } + lineSpacing * CGFloat(max(0, lines.count - 1))

        return CGSize(width: proposal.width ?? lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for line in arrange(subviews: subviews, within: bounds.width) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, within width: CGFloat) -> [Line] {
        var lines = [Line()]

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = lines[lines.count - 1].items.isEmpty ? size.width : size.width + spacing

            if lines[lines.count - 1].width + needed > width, !lines[lines.count - 1].items.isEmpty {
                lines.append(Line())
            }

            var line = lines[lines.count - 1]
            line.items.append((index, size))
            line.width += line.items.count == 1 ? size.width : size.width + spacing
            line.height = max(line.height, size.height)
            lines[lines.count - 1] = line
        }
        return lines
    }
}
