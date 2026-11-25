import Foundation

/// How wide the open capsule is and which widgets go on which page: the same rules as Muna on
/// Linux (linux/src/ui/munaLayout.js). A widget is some cells wide (44 pt each); widgets that do
/// not fit the width go on the next page.
public struct PanelLayout: Equatable {
    public struct Slot: Equatable {
        public let id: String
        public let width: CGFloat
    }

    public static let cell: CGFloat = 44
    public static let gap: CGFloat = 16
    public static let padding: CGFloat = 16
    public static let rowHeight: CGFloat = 112
    public static let minWidth: CGFloat = 560
    public static let maxShare: CGFloat = 0.72
    public static let screenMargin: CGFloat = 24

    public let width: CGFloat
    public let pages: [[Slot]]

    public init(screenWidth: CGFloat, widgets: [String], cells: (String) -> Int, atLeast: CGFloat = 0) {
        let ids = widgets.isEmpty ? ["media"] : widgets
        let maxTotal = max(Self.minWidth, min(screenWidth * Self.maxShare, screenWidth - 2 * Self.screenMargin))
        func natural(_ id: String) -> CGFloat { CGFloat(max(cells(id), 1)) * Self.cell }
        func total(_ list: [String]) -> CGFloat {
            list.reduce(0) { $0 + natural($1) } + CGFloat(max(list.count - 1, 0)) * Self.gap + 2 * Self.padding
        }

        var pageIds: [[String]] = []
        var current: [String] = []
        for id in ids {
            if !current.isEmpty, total(current + [id]) > maxTotal {
                pageIds.append(current)
                current = []
            }
            current.append(id)
        }
        pageIds.append(current)

        var width = max(Self.minWidth, atLeast, pageIds.map(total).max() ?? Self.minWidth)
        width = min(width, max(maxTotal, atLeast)).rounded()
        self.width = width
        pages = pageIds.map { list in
            let inner = width - 2 * Self.padding - CGFloat(max(list.count - 1, 0)) * Self.gap
            let cellsSum = CGFloat(list.reduce(0) { $0 + max(cells($1), 1) })
            return list.map { Slot(id: $0, width: (inner * CGFloat(max(cells($0), 1)) / cellsSum).rounded(.down)) }
        }
    }
}
