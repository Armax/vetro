import CoreGraphics
import Foundation
import GhosttyKit
import Observation

enum SplitAxis { case horizontal, vertical } // horizontal = side-by-side

@MainActor @Observable final class SplitNode: Identifiable {
    let id = UUID()
    weak var parent: SplitNode?
    var surface: TerminalSurface?      // leaf
    var axis: SplitAxis?               // branch
    var a: SplitNode?                  // top/left
    var b: SplitNode?                  // bottom/right
    var ratio: CGFloat = 0.5           // fraction given to `a`
    var isLeaf: Bool { surface != nil }

    init(surface: TerminalSurface) {
        self.surface = surface
    }

    init(axis: SplitAxis, a: SplitNode, b: SplitNode) {
        self.axis = axis
        self.a = a
        self.b = b
    }
}

@MainActor @Observable final class SplitTree {
    var root: SplitNode
    var focused: SplitNode             // always a leaf
    var zoomed: SplitNode?             // leaf temporarily filling the pane
    /// First-created leaf's surface: drives the sidebar dot/title (v1).
    let rootSurface: TerminalSurface

    init(surface: TerminalSurface) {
        let leaf = SplitNode(surface: surface)
        self.root = leaf
        self.focused = leaf
        self.rootSurface = surface
    }

    var leaves: [SplitNode] {
        var out: [SplitNode] = []
        func walk(_ n: SplitNode) {
            if n.isLeaf { out.append(n); return }
            n.a.map(walk)
            n.b.map(walk)
        }
        walk(root)
        return out
    }

    func leaf(for surface: TerminalSurface) -> SplitNode? {
        leaves.first { $0.surface === surface }
    }

    @discardableResult
    func split(
        _ node: SplitNode,
        direction: ghostty_action_split_direction_e,
        newSurface: TerminalSurface
    ) -> SplitNode {
        let newLeaf = SplitNode(surface: newSurface)
        let axis: SplitAxis
        let nodeFirst: Bool                // is `node` in slot a?
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: axis = .horizontal; nodeFirst = true
        case GHOSTTY_SPLIT_DIRECTION_LEFT:  axis = .horizontal; nodeFirst = false
        case GHOSTTY_SPLIT_DIRECTION_DOWN:  axis = .vertical;   nodeFirst = true
        case GHOSTTY_SPLIT_DIRECTION_UP:    axis = .vertical;   nodeFirst = false
        default:                            axis = .horizontal; nodeFirst = true
        }
        let branch = SplitNode(
            axis: axis,
            a: nodeFirst ? node : newLeaf,
            b: nodeFirst ? newLeaf : node
        )
        let oldParent = node.parent
        branch.parent = oldParent
        node.parent = branch
        newLeaf.parent = branch
        if let oldParent {
            if oldParent.a === node { oldParent.a = branch } else { oldParent.b = branch }
        } else {
            root = branch
        }
        zoomed = nil
        focused = newLeaf
        return newLeaf
    }

    /// Removes `node`, hoisting its sibling in place. Returns true when the
    /// tree is now empty (the lone root leaf was closed).
    @discardableResult
    func close(_ node: SplitNode) -> Bool {
        guard let parent = node.parent else { return true }
        guard let sibling = (parent.a === node) ? parent.b : parent.a else { return true }
        let grand = parent.parent
        sibling.parent = grand
        if let grand {
            if grand.a === parent { grand.a = sibling } else { grand.b = sibling }
        } else {
            root = sibling
        }
        if zoomed === node { zoomed = nil }
        if focused === node { focused = firstLeaf(sibling) }
        return false
    }

    func neighbor(of node: SplitNode, goto: ghostty_action_goto_split_e) -> SplitNode? {
        switch goto {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS, GHOSTTY_GOTO_SPLIT_NEXT:
            let all = leaves
            guard all.count > 1, let idx = all.firstIndex(where: { $0 === node }) else { return nil }
            let delta = (goto == GHOSTTY_GOTO_SPLIT_NEXT) ? 1 : -1
            return all[(idx + delta + all.count) % all.count]
        default:
            return directionalNeighbor(of: node, goto: goto)
        }
    }

    func resize(
        _ node: SplitNode,
        direction: ghostty_action_resize_split_direction_e,
        amount: UInt16
    ) {
        let axis: SplitAxis
        let delta: CGFloat
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_RIGHT: axis = .horizontal; delta = CGFloat(amount) / 100
        case GHOSTTY_RESIZE_SPLIT_LEFT:  axis = .horizontal; delta = -CGFloat(amount) / 100
        case GHOSTTY_RESIZE_SPLIT_DOWN:  axis = .vertical;   delta = CGFloat(amount) / 100
        case GHOSTTY_RESIZE_SPLIT_UP:    axis = .vertical;   delta = -CGFloat(amount) / 100
        default: return
        }
        var cur: SplitNode? = node
        while let c = cur {
            if let p = c.parent, p.axis == axis {
                p.ratio = min(0.9, max(0.1, p.ratio + delta))
                return
            }
            cur = c.parent
        }
    }

    func equalize() {
        func walk(_ n: SplitNode) {
            guard !n.isLeaf else { return }
            n.ratio = 0.5
            n.a.map(walk)
            n.b.map(walk)
        }
        walk(root)
    }

    // MARK: - Helpers

    private func firstLeaf(_ n: SplitNode) -> SplitNode {
        var cur = n
        while !cur.isLeaf { cur = cur.a ?? cur.b ?? cur }
        return cur
    }

    private func directionalNeighbor(
        of node: SplitNode,
        goto: ghostty_action_goto_split_e
    ) -> SplitNode? {
        let axis: SplitAxis
        let nodeNear: Bool                  // node must sit on the `a` side to move this way
        switch goto {
        case GHOSTTY_GOTO_SPLIT_RIGHT: axis = .horizontal; nodeNear = true
        case GHOSTTY_GOTO_SPLIT_LEFT:  axis = .horizontal; nodeNear = false
        case GHOSTTY_GOTO_SPLIT_DOWN:  axis = .vertical;   nodeNear = true
        case GHOSTTY_GOTO_SPLIT_UP:    axis = .vertical;   nodeNear = false
        default: return nil
        }
        var child = node
        var parent = node.parent
        while let p = parent {
            if p.axis == axis, (p.a === child) == nodeNear {
                guard let far = nodeNear ? p.b : p.a else { return nil }
                return descend(far, pickA: nodeNear, axis: axis)
            }
            child = p
            parent = p.parent
        }
        return nil
    }

    /// Descend to the leaf on the edge adjacent to the origin pane: along the
    /// travel axis pick the near child, elsewhere pick either.
    private func descend(_ node: SplitNode, pickA: Bool, axis: SplitAxis) -> SplitNode {
        var cur = node
        while !cur.isLeaf {
            if cur.axis == axis {
                cur = (pickA ? cur.a : cur.b) ?? cur.a ?? cur.b ?? cur
            } else {
                cur = cur.a ?? cur.b ?? cur
            }
        }
        return cur
    }
}
