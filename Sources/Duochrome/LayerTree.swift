import Foundation

/// 레이어 배열을 그룹 나무로 다루는 규칙 (배열 앞이 아래).
///
/// 그룹의 자식(손주까지)은 배열에서 그룹 항목 바로 앞에 붙어 있다. 레이어 하나(또는 그룹 덩어리)를
/// 위아래로 옮길 때 그룹에 들어가고 나온다.
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

    /// i번 레이어와 그 자손이 차지하는 범위 (자손은 바로 앞에 붙어 있다).
    static func block(_ layers: [AdjustLayer], _ i: Int) -> ClosedRange<Int> {
        guard layers[i].isGroup else { return i...i }
        var lo = i
        while lo > 0, isDescendant(layers, lo - 1, of: layers[i].id) { lo -= 1 }
        return lo...i
    }

    /// j번 레이어를 품은 것 중 그룹이 `group`인 조상 (같은 층의 형제). 없으면 nil.
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

    /// 위로 한 칸. 그룹의 맨 위 자식이면 그룹 밖(그룹 위)으로, 바로 위 형제가 그룹이면 그 그룹의 맨 아래 자식으로.
    static func moveUp(_ layers: inout [AdjustLayer], _ i: Int) {
        let r = block(layers, i)
        let above = r.upperBound + 1
        guard above < layers.count else { return }
        let me = layers[i]
        if let parent = me.group, layers[above].id == parent {
            // 그룹 밖으로: 그룹 항목 위로
            layers[i].group = layers[above].group
            move(&layers, r, to: above + 1)
            return
        }
        guard let s = sibling(layers, above, group: me.group) else { return }
        if layers[s].isGroup {
            // 형제 그룹의 맨 아래 자식이 된다 (자리는 그대로).
            layers[i].group = layers[s].id
            return
        }
        move(&layers, r, to: s + 1)
    }

    /// 아래로 한 칸. 그룹의 맨 아래 자식이면 그룹 밖(그룹 아래)으로, 바로 아래 형제가 그룹이면 그 그룹의 맨 위 자식으로.
    static func moveDown(_ layers: inout [AdjustLayer], _ i: Int) {
        let r = block(layers, i)
        let below = r.lowerBound - 1
        let me = layers[i]
        if below < 0 || (me.group != nil && sibling(layers, below, group: me.group) == nil) {
            // 그룹 밖으로 (자리는 그대로, 그룹의 아래에 놓인다)
            if let parent = me.group { layers[i].group = layers.first { $0.id == parent }?.group }
            return
        }
        guard let s = sibling(layers, below, group: me.group) else { return }
        if layers[s].isGroup {
            // 형제 그룹의 맨 위 자식: 그룹 항목 바로 아래로
            layers[i].group = layers[s].id
            move(&layers, r, to: s)
            return
        }
        move(&layers, r, to: block(layers, s).lowerBound)
    }

    /// i번 레이어(덩어리)를 새 그룹에 넣는다. 그룹 항목은 덩어리 바로 위에 선다.
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

    /// 그룹을 푼다: 그룹 항목을 지우고 자식은 한 층 올린다.
    static func ungroup(_ layers: inout [AdjustLayer], _ i: Int) {
        guard layers[i].isGroup else { return }
        let g = layers[i]
        for k in layers.indices where layers[k].group == g.id { layers[k].group = g.group }
        layers.remove(at: i)
    }

    /// 레이어(그룹이면 자손까지)를 지운다.
    static func remove(_ layers: inout [AdjustLayer], _ i: Int) {
        layers.removeSubrange(block(layers, i))
    }
}
