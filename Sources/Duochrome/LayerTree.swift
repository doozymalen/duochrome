import Foundation

/// Rules for treating the layer array as a group tree (array front is the bottom).
///
/// A group's children (and grandchildren) sit right before the group item in the array. Moving a layer (or group block)
/// up/down enters and leaves groups.
enum LayerTree {
    static func depth(_ layers: [AdjustLayer], _ i: Int) -> Int {
        var d = 0, p = layers[i].group
        while let id = p, d < 32 { d += 1; p = layers.first { $0.id == id }?.group }
        return d
    }

    static func isDescendant(_ layers: [AdjustLayer], _ i: Int, of groupID: String) -> Bool {
        var p = layers[i].group, n = 0
        while let id = p, n < 32 {
            if id == groupID { return true }
            p = layers.first { $0.id == id }?.group
            n += 1
        }
        return false
    }

    /// Range occupied by layer i and its descendants (descendants sit right before it).
    static func block(_ layers: [AdjustLayer], _ i: Int) -> ClosedRange<Int> {
        guard layers[i].isGroup else { return i...i }
        var lo = i
        while lo > 0, isDescendant(layers, lo - 1, of: layers[i].id) { lo -= 1 }
        return lo...i
    }

    /// Ancestor of layer j whose group is `group` (a sibling at the same level). nil if none.
    private static func sibling(_ layers: [AdjustLayer], _ j: Int, group: String?) -> Int? {
        var k = j, n = 0
        while n < 32 {
            if layers[k].group == group { return k }
            guard let p = layers[k].group, let pi = layers.firstIndex(where: { $0.id == p }) else { return nil }
            k = pi; n += 1
        }
        return nil
    }

    private static func move(_ layers: inout [AdjustLayer], _ r: ClosedRange<Int>, to index: Int) {
        let items = Array(layers[r])
        layers.removeSubrange(r)
        let at = index > r.lowerBound ? index - r.count : index
        layers.insert(contentsOf: items, at: at)
    }

    /// Up one step. The top child of a group leaves it (above the group); if the sibling right above is a group, becomes its bottom child.
    static func moveUp(_ layers: inout [AdjustLayer], _ i: Int) {
        let r = block(layers, i)
        let above = r.upperBound + 1
        guard above < layers.count else { return }
        let me = layers[i]
        if let parent = me.group, layers[above].id == parent {
            // Out of the group: above the group item
            layers[i].group = layers[above].group
            move(&layers, r, to: above + 1)
            return
        }
        guard let s = sibling(layers, above, group: me.group) else { return }
        if layers[s].isGroup {
            // Becomes the bottom child of the sibling group (position unchanged).
            layers[i].group = layers[s].id
            return
        }
        move(&layers, r, to: s + 1)
    }

    /// Down one step. The bottom child of a group leaves it (below the group); if the sibling right below is a group, becomes its top child.
    static func moveDown(_ layers: inout [AdjustLayer], _ i: Int) {
        let r = block(layers, i)
        let below = r.lowerBound - 1
        let me = layers[i]
        if below < 0 || (me.group != nil && sibling(layers, below, group: me.group) == nil) {
            // Out of the group (position unchanged, placed below the group)
            if let parent = me.group { layers[i].group = layers.first { $0.id == parent }?.group }
            return
        }
        guard let s = sibling(layers, below, group: me.group) else { return }
        if layers[s].isGroup {
            // Top child of the sibling group: right below the group item
            layers[i].group = layers[s].id
            move(&layers, r, to: s)
            return
        }
        move(&layers, r, to: block(layers, s).lowerBound)
    }

    /// Puts layer i (block) into a new group. The group item sits right above the block.
    @discardableResult
    static func groupLayer(_ layers: inout [AdjustLayer], _ i: Int, name: String) -> String {
        let r = block(layers, i)
        var g = AdjustLayer(name: name)
        g.kind = "group"
        g.blend = Layers.passThroughKey
        g.group = layers[i].group
        layers[i].group = g.id
        layers.insert(g, at: r.upperBound + 1)
        return g.id
    }

    /// Ungroups: removes the group item and moves children up one level.
    static func ungroup(_ layers: inout [AdjustLayer], _ i: Int) {
        guard layers[i].isGroup else { return }
        let g = layers[i]
        for k in layers.indices where layers[k].group == g.id { layers[k].group = g.group }
        layers.remove(at: i)
    }

    /// Removes a layer (with descendants if a group).
    static func remove(_ layers: inout [AdjustLayer], _ i: Int) {
        layers.removeSubrange(block(layers, i))
    }
}
