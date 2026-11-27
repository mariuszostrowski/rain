//
//  BokehField.swift
//  rain
//
//  Procedural light sources of a night street, seen out of focus.
//  The camera is focused on the glass (~0.5 m), so every light in the street
//  becomes a disc of nearly the same size (circle of confusion → constant for
//  distant objects). Brightness, colour and motion tell the story instead.
//

import Foundation
import simd

final class BokehField {

    private enum Kind { case window, neon, screen }

    private struct Lamp {
        var lane: Float, height: Float, depth: Float
        var color: SIMD3<Float>
        var power: Float, size: Float, seed: Float
        var faulty: Bool
    }

    private struct Car {
        var lane: Float, depth: Float, speed: Float, cruise: Float
        var oncoming: Bool
        var color: SIMD3<Float>
        var power: Float, size: Float, seed: Float
        var brake: Float, age: Float
    }

    private struct Glow {
        var x: Float, y: Float
        var color: SIMD3<Float>
        var power: Float, size: Float, seed: Float
        var level: Float, target: Float, timer: Float
        var kind: Kind
    }

    private static let sodium = SIMD3<Float>(1.0, 0.50, 0.15)
    private static let ledWhite = SIMD3<Float>(0.82, 0.90, 1.0)
    private static let headlightWarm = SIMD3<Float>(1.0, 0.90, 0.74)
    private static let headlightLED = SIMD3<Float>(0.86, 0.93, 1.0)
    private static let tailRed = SIMD3<Float>(1.0, 0.035, 0.02)
    private static let windowColors: [SIMD3<Float>] = [
        SIMD3(1.0, 0.72, 0.42), SIMD3(1.0, 0.84, 0.60), SIMD3(0.95, 0.62, 0.30), SIMD3(0.78, 0.86, 1.0)
    ]
    private static let neonColors: [SIMD3<Float>] = [
        SIMD3(1.0, 0.12, 0.55), SIMD3(0.10, 0.80, 1.0), SIMD3(0.30, 0.35, 1.0), SIMD3(1.0, 0.25, 0.10)
    ]

    private enum Style: CaseIterable { case sodium, modern, neonDistrict, mixed }

    // Randomised per session in build()
    private var style: Style = .mixed
    private var camHeight: Float = 1.45
    private var focal: Float = 0.8
    private var horizon: Float = 0.5
    private var vanishFrac: Float = 0.5
    private var baseRadius: Float = 0.058
    private var signalDepth: Float = 30
    private var signalLane: Float = 5.2
    private var hasSignal = true
    private var signalOffset: Float = 0
    private var carInterval: ClosedRange<Float> = 1.0...4.5
    private var warmth: Float = 1
    private var skylineSeed: Float = 0

    /// vanishX (fraction of width), horizon, haze warmth, skyline seed — for the procedural street.
    var sceneParams: SIMD4<Float> { SIMD4(vanishFrac, horizon, warmth, skylineSeed) }

    private var rng: RandomGenerator
    private var lamps: [Lamp] = []
    private var cars: [Car] = []
    private var glows: [Glow] = []
    private var lights: [GPUBokeh] = []
    private var aspect: Float = 0
    private var time: Float = 0
    private var nextCar: Float = 0.5

    init(seed: UInt64) {
        rng = RandomGenerator(seed: seed)
        lights.reserveCapacity(512)
    }

    func update(dt: Float, aspect newAspect: Float) {
        if abs(newAspect - aspect) > 0.01 {
            aspect = newAspect
            build()
        }
        time += dt
        updateCars(dt: dt)
        updateGlows(dt: dt)
        emitAll()
    }

    func write(into p: UnsafeMutablePointer<GPUBokeh>, capacity: Int) -> Int {
        let n = min(capacity, lights.count)
        for i in 0..<n { p[i] = lights[i] }
        return n
    }

    // MARK: - Geometry

    private func project(_ lane: Float, _ height: Float, _ depth: Float) -> SIMD2<Float> {
        SIMD2(aspect * vanishFrac + lane / depth * focal,
              horizon + (camHeight - height) / depth * focal)
    }

    /// Circle of confusion for a lens focused at 0.5 m.
    private func blurRadius(_ depth: Float) -> Float {
        baseRadius * (1 - 0.5 / max(depth, 1))
    }

    private func fadeFar(_ depth: Float) -> Float { 1 - smoothStep(95, 135, depth) }

    // MARK: - Scene setup

    private func build() {
        lamps.removeAll()
        glows.removeAll()
        cars.removeAll()

        // A different street every time the saver starts
        style = Style.allCases[Int(rng.unit() * Float(Style.allCases.count)) % Style.allCases.count]
        horizon = rng.range(0.40, 0.60)
        vanishFrac = rng.range(0.28, 0.72)
        camHeight = rng.range(1.1, 2.4)
        focal = rng.range(0.65, 1.0)
        baseRadius = rng.range(0.042, 0.078)
        hasSignal = rng.chance(0.75)
        signalDepth = rng.range(18, 45)
        signalLane = (rng.chance(0.5) ? 1 : -1) * rng.range(4.5, 6.5)
        signalOffset = rng.range(0, 34)
        let busy = rng.range(0.6, 4.0)
        carInterval = (busy * 0.6)...(busy * 2.2)
        skylineSeed = rng.range(0, 100)

        let sodiumShare: Float
        switch style {
        case .sodium:       sodiumShare = 0.95; warmth = 1.0
        case .modern:       sodiumShare = 0.05; warmth = 0.25
        case .neonDistrict: sodiumShare = 0.4;  warmth = 0.55
        case .mixed:        sodiumShare = 0.6;  warmth = 0.7
        }

        for side: Float in [-1, 1] {
            let sodiumStreet = rng.chance(sodiumShare)
            let spacing = rng.range(11, 22)
            var depth = rng.range(5, 10)
            while depth < 130 {
                let base = sodiumStreet ? Self.sodium : Self.ledWhite
                lamps.append(Lamp(lane: side * rng.range(6.5, 8.0),
                                  height: rng.range(5.5, 7.0),
                                  depth: depth,
                                  color: base * rng.range(0.9, 1.05),
                                  power: rng.range(0.85, 1.2),
                                  size: rng.range(0.9, 1.1),
                                  seed: rng.unit(),
                                  faulty: rng.chance(0.07)))
                depth += spacing * rng.range(0.85, 1.15)
            }
        }

        let windowCount = style == .neonDistrict ? Int(rng.range(18, 30)) : Int(rng.range(6, 24))
        let neonCount = style == .neonDistrict ? Int(rng.range(5, 9)) : Int(rng.range(0, 4))
        let screenCount = Int(rng.range(0, 3.99))

        for _ in 0..<windowCount {
            let x = rng.range(0, aspect)
            let side = abs(x / aspect - 0.5) * 2
            let y = horizon - (side > 0.3 ? rng.range(0.04, 0.36) : rng.range(0.02, 0.12))
            let on = rng.chance(0.7)
            glows.append(Glow(x: x, y: y,
                              color: Self.windowColors[Int(rng.unit() * Float(Self.windowColors.count)) % Self.windowColors.count],
                              power: rng.range(0.12, 0.35), size: rng.range(0.55, 0.9), seed: rng.unit(),
                              level: on ? 1 : 0, target: on ? 1 : 0, timer: rng.range(10, 150),
                              kind: .window))
        }
        for _ in 0..<neonCount {
            let right = rng.chance(0.5)
            let x = aspect * (right ? rng.range(0.62, 0.98) : rng.range(0.02, 0.38))
            glows.append(Glow(x: x, y: horizon + rng.range(-0.2, -0.02),
                              color: Self.neonColors[Int(rng.unit() * Float(Self.neonColors.count)) % Self.neonColors.count],
                              power: rng.range(0.45, 0.8), size: rng.range(0.75, 1.0), seed: rng.unit(),
                              level: 1, target: 1, timer: 0, kind: .neon))
        }
        for _ in 0..<screenCount {
            glows.append(Glow(x: rng.range(0, aspect), y: horizon + rng.range(-0.3, -0.08),
                              color: SIMD3(0.55, 0.68, 1.0),
                              power: rng.range(0.15, 0.25), size: rng.range(0.6, 0.8), seed: rng.unit(),
                              level: 1, target: 1, timer: 0, kind: .screen))
        }

        for _ in 0..<Int(rng.range(2, 7)) { spawnCar(randomDepth: true) }
    }

    // MARK: - Traffic

    private var signalPhase: Float { (time + signalOffset).truncatingRemainder(dividingBy: 34) }
    private var signalStop: Bool { hasSignal && signalPhase >= 15 }

    private var signalColor: SIMD3<Float> {
        let p = signalPhase
        if p < 15 { return SIMD3(0.10, 1.0, 0.55) }
        if p < 18 { return SIMD3(1.0, 0.62, 0.04) }
        return SIMD3(1.0, 0.05, 0.03)
    }

    private func spawnCar(randomDepth: Bool) {
        let oncoming = rng.chance(0.55)
        let cruise = rng.range(8, 15)
        let depth: Float = randomDepth ? rng.range(10, 100) : (oncoming ? 135 : 2.2)
        cars.append(Car(lane: oncoming ? -rng.range(1.4, 2.4) : rng.range(1.4, 2.4),
                        depth: depth, speed: cruise, cruise: cruise,
                        oncoming: oncoming,
                        color: rng.chance(0.5) ? Self.headlightWarm : Self.headlightLED,
                        power: rng.range(0.8, 1.2), size: rng.range(0.93, 1.07), seed: rng.unit(),
                        brake: 0, age: randomDepth ? 10 : 0))
        if cars.count > 14 { cars.removeFirst() }
    }

    private func updateCars(dt: Float) {
        nextCar -= dt
        if nextCar <= 0 {
            spawnCar(randomDepth: false)
            nextCar = rng.range(carInterval.lowerBound, carInterval.upperBound)
        }
        let stop = signalStop
        for i in cars.indices {
            var c = cars[i]
            c.age += dt
            if c.oncoming {
                c.depth -= c.speed * dt
            } else {
                let stopping = stop && c.depth > signalDepth - 14 && c.depth < signalDepth - 2
                let target: Float = stopping ? 0 : c.cruise
                c.speed += (target - c.speed) * min(1, dt * (stopping ? 0.9 : 0.5))
                c.brake += ((stopping ? 1 : 0) - c.brake) * min(1, dt * 6)
                c.depth += c.speed * dt
            }
            cars[i] = c
        }
        cars.removeAll { $0.oncoming ? $0.depth < 1.6 : $0.depth > 140 }
    }

    // MARK: - Windows, neon, screens

    private func updateGlows(dt: Float) {
        for i in glows.indices {
            var g = glows[i]
            switch g.kind {
            case .window:
                g.timer -= dt
                if g.timer <= 0 {
                    g.target = g.target > 0.5 ? 0 : 1
                    g.timer = rng.range(20, 150)
                }
                g.level += (g.target - g.level) * min(1, dt * 4)
            case .neon:
                if g.timer > 0 {
                    g.timer -= dt
                    g.level = rng.chance(0.5) ? 1 : 0.08
                } else {
                    g.level += (1 - g.level) * min(1, dt * 10)
                    if rng.chance(dt * 0.04) { g.timer = rng.range(0.25, 1.2) }
                }
            case .screen:
                g.level = 0.55 + 0.45 * sin(time * 2.3 + g.seed * 30) * sin(time * 0.7 + g.seed * 11)
            }
            glows[i] = g
        }
    }

    // MARK: - Emission

    private func emit(_ p: SIMD2<Float>, _ radius: Float, _ intensity: Float, _ color: SIMD3<Float>, _ seed: Float) {
        guard intensity > 0.004, radius > 0.001 else { return }
        guard p.x > -radius, p.x < aspect + radius, p.y > -radius, p.y < 1 + radius else { return }
        guard lights.count < 512 else { return }
        lights.append(GPUBokeh(a: SIMD4(p.x, p.y, radius, intensity),
                               b: SIMD4(color.x, color.y, color.z, seed)))
    }

    /// A light plus its smeared reflection in the wet asphalt.
    private func emitReflected(lane: Float, height: Float, depth: Float,
                               radius: Float, intensity: Float, color: SIMD3<Float>, seed: Float) {
        emit(project(lane, height, depth), radius, intensity, color, seed)
        emit(project(lane, -height * 0.55, depth), radius * 0.95, intensity * 0.22, color, seed + 0.31)
        emit(project(lane, -height, depth), radius * 0.9, intensity * 0.14, color, seed + 0.57)
        emit(project(lane, -height * 1.6, depth), radius * 0.85, intensity * 0.07, color, seed + 0.83)
    }

    private func emitAll() {
        lights.removeAll(keepingCapacity: true)

        for l in lamps {
            var level: Float = 1
            if l.faulty {
                let f = sin(time * 17 + l.seed * 40) * sin(time * 5.3 + l.seed * 13)
                level = f > 0.55 ? 0.12 : 1
            }
            emitReflected(lane: l.lane, height: l.height, depth: l.depth,
                          radius: blurRadius(l.depth) * l.size,
                          intensity: l.power * level * 2.6 / (1 + l.depth * 0.11) * fadeFar(l.depth),
                          color: l.color, seed: l.seed)
        }

        if hasSignal {
            emitReflected(lane: signalLane, height: 4.2, depth: signalDepth,
                          radius: blurRadius(signalDepth) * 0.9, intensity: 0.95,
                          color: signalColor, seed: 0.77)
        }

        for c in cars {
            let nearFade: Float = c.oncoming ? smoothStep(1.6, 4.5, c.depth) : 1
            let fade = fadeFar(c.depth) * min(1, c.age * 1.2) * nearFade
            let r = blurRadius(c.depth) * c.size
            for side: Float in [-1, 1] {
                let lane = c.lane + side * 0.78
                if c.oncoming {
                    emitReflected(lane: lane, height: 0.68, depth: c.depth, radius: r,
                                  intensity: c.power * 3.2 / (1 + c.depth * 0.09) * fade,
                                  color: c.color, seed: c.seed + side * 0.1)
                } else {
                    emitReflected(lane: lane, height: 0.8, depth: c.depth, radius: r * 0.9,
                                  intensity: c.power * (0.55 + 1.3 * c.brake) * 2.2 / (1 + c.depth * 0.09) * fade,
                                  color: Self.tailRed, seed: c.seed + side * 0.1)
                }
            }
        }

        for g in glows {
            emit(SIMD2(g.x, g.y), baseRadius * g.size, g.power * g.level, g.color, g.seed)
        }
    }
}
