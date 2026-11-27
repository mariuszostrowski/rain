//
//  DropSimulation.swift
//  rain
//
//  CPU simulation of water drops on a vertical pane.
//  Units: y = 0…1 (top → bottom), x = 0…aspect. Radii are fractions of screen height.
//
//  Behaviour:
//   • rain lands as small static drops; overlapping drops merge (area is conserved)
//   • once heavy enough a drop breaks loose and slides with stick-slip motion,
//     meandering sideways, absorbing everything in its path
//   • a sliding drop sheds tiny droplets behind it and loses mass; it stops when too light
//   • shed droplets slowly evaporate; the fog pass makes the cleared path re-fog over time
//

import Foundation

struct RandomGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func unit() -> Float { Float(next() >> 40) * (1.0 / 16_777_216.0) }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
    mutating func chance(_ p: Float) -> Bool { unit() < p }
}

@inline(__always) func smoothStep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

final class DropSimulation {

    struct Drop {
        var x: Float
        var y: Float
        var r: Float
        var vx: Float = 0
        var vy: Float = 0
        var moving = false
        var stall: Float = 0
        var travelled: Float = 0
        var nextTrail: Float = 0
        var grow: Float = 1
        var stretch: Float = 1
        var evaporation: Float = 0 // radius lost per second (shed droplets only)
        var dead = false
    }

    private var drops: [Drop] = []
    private var pending: [Drop] = []
    private var rng: RandomGenerator
    private var spawnAccumulator: Float = 0
    private var aspect: Float = 0
    private var time: Float = 0
    private let detail: Float

    var rainIntensity: Float = 1

    // Tuning
    private let minRadius: Float = 0.0022
    private let maxRadius: Float = 0.0125
    private let slideRadius: Float = 0.0068
    private let stopRadius: Float = 0.0042
    private let maxMergedRadius: Float = 0.028
    private var softLimit: Int { Int(1600 * detail) }
    private var hardLimit: Int { Int(2400 * detail) }

    init(seed: UInt64, detail: Float) {
        self.rng = RandomGenerator(seed: seed)
        self.detail = detail
        drops.reserveCapacity(2600)
        pending.reserveCapacity(64)
    }

    // MARK: - Update

    func update(dt: Float, aspect newAspect: Float) {
        if abs(newAspect - aspect) > 0.01 {
            aspect = newAspect
            reseed()
        }
        time += dt

        // Rain arrives in slow gusts
        let gust = 0.55 + 0.9 * (0.5 + 0.5 * sin(time * 0.11) * sin(time * 0.047 + 1.3))
        spawnAccumulator += 26 * aspect * rainIntensity * detail * gust * dt
        while spawnAccumulator >= 1 {
            spawnAccumulator -= 1
            spawnRainDrop()
        }

        for i in drops.indices {
            var d = drops[i]
            if d.dead { continue }
            if d.grow < 1 { d.grow = min(1, d.grow + dt * 9) }
            if d.moving { slide(&d, dt: dt) } else { rest(&d, dt: dt) }
            drops[i] = d
        }

        mergeSliding()

        drops.removeAll { $0.dead }
        drops.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if drops.count > hardLimit {
            drops.removeFirst(drops.count - hardLimit)
        }
    }

    func write(into p: UnsafeMutablePointer<GPUDrop>, capacity: Int) -> Int {
        var n = 0
        for d in drops where n < capacity {
            let g = 1 - (1 - d.grow) * (1 - d.grow) // ease-out appearance
            p[n] = GPUDrop(a: SIMD4(d.x, d.y, d.r * g, d.stretch),
                           b: SIMD4(d.vx, d.vy, 0, 0))
            n += 1
        }
        return n
    }

    // MARK: - Drop behaviour

    private func rest(_ d: inout Drop, dt: Float) {
        if d.evaporation > 0 {
            d.r -= d.evaporation * dt
            if d.r < 0.0008 { d.dead = true; return }
        }
        d.stretch += (1 - d.stretch) * min(1, dt * 5)
        if d.r > slideRadius && rng.chance((d.r - slideRadius) * 140 * dt) {
            d.moving = true
            d.vy = 0.02
            d.evaporation = 0
            d.travelled = 0
            d.nextTrail = d.r * rng.range(1.0, 2.5)
        }
    }

    private func slide(_ d: inout Drop, dt: Float) {
        let terminal = min(0.5, max(0.04, (d.r - 0.0045) * 52))

        if d.stall > 0 {
            d.stall -= dt
            d.vy *= exp(-dt * 14)
        } else {
            d.vy += (terminal - d.vy) * min(1, dt * 3)
            // lighter drops catch on the glass more often
            let stallRate = max(0.1, 1.4 - (d.r - slideRadius) * 120)
            if rng.chance(stallRate * dt) { d.stall = rng.range(0.08, 0.9) }
        }

        d.vx = d.vx * exp(-dt * 3) + rng.range(-1, 1) * d.vy * 1.6 * dt
        let lim = d.vy * 0.35
        d.vx = min(max(d.vx, -lim), lim)

        d.x += d.vx * dt
        d.y += d.vy * dt
        d.travelled += d.vy * dt

        if d.travelled >= d.nextTrail {
            d.travelled = 0
            let tr = d.r * rng.range(0.14, 0.34)
            var t = Drop(x: d.x + rng.range(-0.35, 0.35) * d.r,
                         y: d.y - d.r * rng.range(1.15, 1.7),
                         r: tr)
            t.evaporation = tr / rng.range(25, 70)
            pending.append(t)
            d.r = sqrt(max(d.r * d.r - tr * tr * 0.5, 0))
            d.nextTrail = d.r * rng.range(0.9, 3.2)
        }

        d.stretch = 1 + min(0.75, d.vy * 1.8)

        if d.r < stopRadius {
            d.moving = false
            d.vx = 0
            d.vy = 0
            d.evaporation = d.r / rng.range(60, 120)
        }
        if d.y - d.r > 1.05 || d.x < -0.1 || d.x > aspect + 0.1 { d.dead = true }
    }

    private func mergeSliding() {
        for i in drops.indices where drops[i].moving && !drops[i].dead {
            for j in drops.indices where j != i && !drops[j].dead {
                let dx = drops[j].x - drops[i].x
                let dy = drops[j].y - drops[i].y
                let lim = (drops[i].r + drops[j].r) * 0.72
                guard dx * dx + dy * dy < lim * lim else { continue }

                let a2 = drops[i].r * drops[i].r
                let b2 = drops[j].r * drops[j].r
                let total = a2 + b2
                drops[i].x = (drops[i].x * a2 + drops[j].x * b2) / total
                drops[i].y = max(drops[i].y, (drops[i].y * a2 + drops[j].y * b2) / total)
                drops[i].r = min(sqrt(total), maxMergedRadius)
                drops[i].vy += 0.04
                drops[i].stall = 0
                drops[j].dead = true
            }
        }
    }

    // MARK: - Spawning

    private func randomRadius() -> Float {
        if rng.chance(0.04) { return rng.range(0.011, 0.016) }
        return minRadius + (maxRadius - minRadius) * pow(rng.unit(), 2.8)
    }

    private func spawnRainDrop() {
        let r = randomRadius()
        let x = rng.range(-0.01, aspect + 0.01)
        let y = rng.range(-0.02, 1.0)
        for i in drops.indices where !drops[i].dead {
            let dx = drops[i].x - x, dy = drops[i].y - y
            let lim = (drops[i].r + r) * 0.8
            if dx * dx + dy * dy < lim * lim {
                drops[i].r = min(sqrt(drops[i].r * drops[i].r + r * r), maxMergedRadius)
                drops[i].evaporation = 0
                return
            }
        }
        guard drops.count < softLimit else { return }
        var d = Drop(x: x, y: y, r: r)
        d.grow = 0
        drops.append(d)
    }

    private func reseed() {
        drops.removeAll(keepingCapacity: true)
        let count = Int(420 * detail * aspect / 1.6)
        for _ in 0..<count {
            var r = randomRadius()
            if r > slideRadius { r = rng.range(0.004, slideRadius) }
            drops.append(Drop(x: rng.range(0, aspect), y: rng.range(0, 1), r: r))
        }
    }
}
