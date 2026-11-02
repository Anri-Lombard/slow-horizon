import CoreGraphics
import Foundation
import simd

// Set with `defaults write`. Without a saved place, the time zone gives a longitude close enough
// for the sun to be right to within about an hour, and needs no location permission.
let place: (lat: Double, lon: Double) = {
    let saved = UserDefaults.standard
    if saved.object(forKey: "latitude") != nil, saved.object(forKey: "longitude") != nil {
        return (saved.double(forKey: "latitude"), saved.double(forKey: "longitude"))
    }
    let zone = TimeZone.current
    return (35, (Double(zone.secondsFromGMT()) - zone.daylightSavingTimeOffset()) / 240)
}()
let horizonFraction = 0.40
private let azimuthHalfSpan = 125.0 * .pi / 180

struct Equatorial {
    var ra: Double
    var dec: Double
    var dist = 0.0
}

struct Horizontal {
    var alt: Double
    var az: Double
}

// Low-precision ephemeris after Meeus, as used by SunCalc.
private let rad = Double.pi / 180
private let obliquity = 23.4397 * rad

func daysSinceJ2000(_ date: Date) -> Double {
    date.timeIntervalSince1970 * 1000 / 86_400_000 - 0.5 + 2_440_588 - 2_451_545
}

private func rightAscension(_ l: Double, _ b: Double) -> Double {
    atan2(sin(l) * cos(obliquity) - tan(b) * sin(obliquity), cos(l))
}

private func declination(_ l: Double, _ b: Double) -> Double {
    asin(sin(b) * cos(obliquity) + cos(b) * sin(obliquity) * sin(l))
}

func sunEquatorial(_ d: Double) -> Equatorial {
    let m = rad * (357.5291 + 0.98560028 * d)
    let c = rad * (1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m))
    let l = m + c + rad * 102.9372 + .pi
    return Equatorial(ra: rightAscension(l, 0), dec: declination(l, 0))
}

func moonEquatorial(_ d: Double) -> Equatorial {
    let lon = rad * (218.316 + 13.176396 * d)
    let m = rad * (134.963 + 13.064993 * d)
    let f = rad * (93.272 + 13.22935 * d)
    let l = lon + rad * 6.289 * sin(m)
    let b = rad * 5.128 * sin(f)
    return Equatorial(ra: rightAscension(l, b), dec: declination(l, b), dist: 385_001 - 20905 * cos(m))
}

func horizontal(_ body: Equatorial, _ d: Double) -> Horizontal {
    let h = rad * (280.16 + 360.9856235 * d) + place.lon * rad - body.ra
    let phi = place.lat * rad
    return Horizontal(
        alt: asin(sin(phi) * sin(body.dec) + cos(phi) * cos(body.dec) * cos(h)),
        az: atan2(sin(h), cos(h) * sin(phi) - tan(body.dec) * cos(phi)) + .pi
    )
}

// The view faces the equator and spans 250 degrees. Far from mid-latitudes the sun can pass behind
// the viewer for part of the day.
func skyX(_ az: Double) -> Double {
    let facing = place.lat < 0 ? 0 : Double.pi
    let offset = az - facing
    return 0.5 + atan2(sin(offset), cos(offset)) / (2 * azimuthHalfSpan)
}

func skyY(_ alt: Double) -> Double {
    horizonFraction + (1 - horizonFraction) * (alt / (.pi / 2))
}

func moonIllumination(sun: Equatorial, moon: Equatorial) -> Double {
    let sunDistance = 149_598_000.0
    let phi = acos(sin(sun.dec) * sin(moon.dec) + cos(sun.dec) * cos(moon.dec) * cos(sun.ra - moon.ra))
    let inc = atan2(sunDistance * sin(phi), moon.dist - sunDistance * cos(phi))
    return (1 + cos(inc)) / 2
}

// Direction from the moon towards the sun on screen, so the lit limb faces the sun as it does outside.
private func limbAngle(moon: Horizontal, sun: Horizontal) -> Double {
    let unit = { (p: Horizontal) in SIMD3(cos(p.alt) * sin(p.az), cos(p.alt) * cos(p.az), sin(p.alt)) }
    let m = unit(moon), s = unit(sun)
    let toward = s - dot(m, s) * m
    let azHat = SIMD3(cos(moon.az), -sin(moon.az), 0)
    let altHat = SIMD3(-sin(moon.alt) * sin(moon.az), -sin(moon.alt) * cos(moon.az), cos(moon.alt))
    return atan2(dot(toward, azHat), dot(toward, altHat))
}

func smooth(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let k = min(1, max(0, (x - lo) / (hi - lo)))
    return k * k * (3 - 2 * k)
}

// Seeded so the waves and the faint stars are the same on every launch.
struct SeededRandom {
    private var seed: UInt32
    init(_ seed: UInt32) { self.seed = seed }
    mutating func next() -> Double {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Double(seed) / 4_294_967_296
    }
}

// The bright stars are real (RA hours, Dec degrees, magnitude); the faint field is seeded.
private let stars: [(ra: Double, dec: Double, mag: Double)] = {
    let bright: [(Double, Double, Double)] = [
        (6.752, -16.72, -1.46), (6.399, -52.70, -0.74), (14.261, 19.18, -0.05), (14.660, -60.83, -0.01), (18.616, 38.78, 0.03),
        (5.278, 46.00, 0.08), (5.242, -8.20, 0.13), (7.655, 5.22, 0.34), (1.629, -57.24, 0.46), (5.919, 7.41, 0.45),
        (14.064, -60.37, 0.61), (19.846, 8.87, 0.76), (12.443, -63.10, 0.77), (4.599, 16.51, 0.86), (16.490, -26.43, 1.06),
        (13.420, -11.16, 0.97), (7.755, 28.03, 1.14), (22.961, -29.62, 1.16), (20.690, 45.28, 1.25), (12.795, -59.69, 1.25),
        (10.139, 11.97, 1.35), (6.977, -28.97, 1.50), (7.577, 31.89, 1.58), (17.560, -37.10, 1.62), (12.519, -57.11, 1.63),
        (5.419, 6.35, 1.64), (5.438, 28.61, 1.65), (9.220, -69.72, 1.67), (5.604, -1.20, 1.69), (22.137, -46.96, 1.74),
        (5.679, -1.94, 1.77), (12.900, 55.96, 1.76), (3.405, 49.86, 1.79), (11.062, 61.75, 1.79), (7.140, -26.39, 1.83),
        (18.403, -34.38, 1.85), (17.622, -43.00, 1.87), (8.375, -59.51, 1.86), (13.792, 49.31, 1.86), (5.992, 44.95, 1.90),
        (16.811, -69.03, 1.91), (6.629, 16.40, 1.92), (20.427, -56.74, 1.94), (2.530, 89.26, 1.98), (6.378, -17.96, 1.98),
        (9.460, -8.66, 1.98), (2.120, 23.46, 2.00), (0.727, -17.99, 2.02), (18.921, -26.30, 2.05), (14.111, -36.37, 2.06),
        (5.796, -9.67, 2.06), (5.533, -0.30, 2.23), (0.140, 29.09, 2.06), (1.162, 35.62, 2.05), (21.736, 9.88, 2.38),
        (23.079, 15.21, 2.49), (23.063, 28.08, 2.42), (0.221, 15.18, 2.83), (20.370, 40.26, 2.23), (19.512, 27.96, 3.05),
        (17.582, 12.56, 2.07), (11.818, 14.57, 2.11), (3.136, 40.96, 2.10), (3.791, 24.10, 2.87),
    ]
    var random = SeededRandom(20_261_102)
    let faint = (0..<1400).map { _ -> (ra: Double, dec: Double, mag: Double) in
        let ra = random.next() * 2 * .pi
        let dec = asin(2 * random.next() - 1)
        return (ra, dec, 3.2 + 2.8 * random.next().squareRoot())
    }
    return bright.map { (ra: $0.0 * 15 * rad, dec: $0.1 * rad, mag: $0.2) } + faint
}()

// Draws into a bitmap the size of the sky layer, with y counted up from the horizon.
func paintStarLayer(
    _ context: CGContext, sceneHeight: Double, date: Date, night: Double,
    sunPosition: Horizontal, moonPosition: Horizontal, sun: Equatorial, moon: Equatorial
) {
    let width = Double(context.width), height = Double(context.height), d = daysSinceJ2000(date)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let unit = sceneHeight / 720
    let toLayerY = { (alt: Double) in (skyY(alt) - horizonFraction) * sceneHeight }

    if night > 0.01 {
        for star in stars {
            let position = horizontal(Equatorial(ra: star.ra, dec: star.dec), d)
            guard position.alt >= 0.02 else { continue }
            let x = skyX(position.az)
            guard x >= 0, x <= 1 else { continue }
            let light = pow(2.512, -star.mag) * smooth(0.02, 0.3, position.alt)
            let size = max(0.55, 1.5 - star.mag * 0.3) * unit
            let alpha = min(0.92, night * (0.1 + 1.5 * light.squareRoot()))
            context.setFillColor(CGColor(red: 214.0 / 255, green: 222.0 / 255, blue: 236.0 / 255, alpha: alpha))
            context.fillEllipse(in: CGRect(x: x * width - size, y: toLayerY(position.alt) - size, width: size * 2, height: size * 2))
        }
    }

    if moonPosition.alt > -0.02 {
        let r = 13 * unit
        let bulge = r * (2 * moonIllumination(sun: sun, moon: moon) - 1)
        context.saveGState()
        context.translateBy(x: skyX(moonPosition.az) * width, y: toLayerY(moonPosition.alt))
        context.rotate(by: -limbAngle(moon: moonPosition, sun: sunPosition))
        context.setFillColor(CGColor(red: 232.0 / 255, green: 232.0 / 255, blue: 222.0 / 255, alpha: 0.08 + 0.62 * night))
        // The lit limb is drawn upward; the terminator is an ellipse whose width follows the phase.
        context.move(to: CGPoint(x: -r, y: 0))
        context.addArc(center: .zero, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
        for step in 1...48 {
            let angle = Double(step) / 48 * .pi
            context.addLine(to: CGPoint(x: r * cos(angle), y: -bulge * sin(angle)))
        }
        context.fillPath()
        context.restoreGState()
    }
}

// SeededRandom is linear, so consecutive seeds would give evenly stepped values and the weather
// would repeat as a sawtooth. This scrambles the seed first.
private func scrambled(_ step: Int, seed: UInt32) -> SeededRandom {
    var h = UInt32(truncatingIfNeeded: step) &+ seed &* 0x9E37_79B9
    h ^= h >> 16
    h = h &* 0x85EB_CA6B
    h ^= h >> 13
    h = h &* 0xC2B2_AE35
    h ^= h >> 16
    return SeededRandom(h)
}

// Weather and traffic are worked out from the clock alone, so they keep their place across restarts.
private func drifting(_ value: Double, seed: UInt32) -> Double {
    func at(_ step: Double) -> Double {
        var random = scrambled(Int(step), seed: seed)
        return random.next()
    }
    let step = value.rounded(.down)
    return at(step) + (at(step + 1) - at(step)) * smooth(0, 1, value - step)
}

// Each value builds over hours. A change this slow is never seen happening, so it can't pull the
// eye; it is only noticed later that the afternoon has clouded over.
struct Weather {
    var cover, wind, fog, rain, rainX: Double

    static func at(_ date: Date) -> Weather {
        let hours = date.timeIntervalSince1970 / 3600
        let cover = smooth(0.3, 0.85, drifting(hours / 5, seed: 1) * 0.6 + drifting(hours / 17, seed: 2) * 0.4)
        let rain = smooth(0.6, 0.85, cover) * smooth(0.5, 0.72, drifting(hours / 3, seed: 3))
        return Weather(
            cover: cover,
            wind: min(1, drifting(hours / 7, seed: 5) * 0.8 + cover * 0.25),
            fog: smooth(0.82, 0.95, drifting(hours / 9, seed: 4)) * (1 - rain),
            rain: rain,
            rainX: 0.1 + 0.8 * drifting(hours / 6, seed: 6)
        )
    }
}

// x across the screen, height of the waterline in the scene, size, direction. A size of zero means
// out of sight. Crossings take hours, so a boat is never seen moving, only found to have moved.
typealias Traffic = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

func boats(at date: Date) -> Traffic {
    let minutes = date.timeIntervalSince1970 / 60
    func boat(cycle: Double, crossing: Double, offset: Double, below: Double, size: Float) -> SIMD4<Float> {
        let round = ((minutes + offset) / cycle).rounded(.down)
        let progress = (minutes + offset - round * cycle) / crossing
        guard progress < 1 else { return .zero }
        let eastbound = Int(round) % 2 != 0
        let x = eastbound ? progress * 1.04 - 0.02 : 1.02 - progress * 1.04
        return SIMD4(Float(x), Float(horizonFraction - below), size, eastbound ? 1 : -1)
    }
    return (
        boat(cycle: 420, crossing: 150, offset: 0, below: 0, size: 1),
        boat(cycle: 560, crossing: 190, offset: 70, below: 0.006, size: 1),
        boat(cycle: 700, crossing: 140, offset: 170, below: 0.016, size: 1.5),
        // The rare ones: a tall ship about weekly, an iceberg that takes two days to pass.
        boat(cycle: 9000, crossing: 170, offset: 1200, below: 0.003, size: 1),
        boat(cycle: 60000, crossing: 2880, offset: 20000, below: 0, size: 1.3)
    )
}

// Rare enough that nobody sits waiting for one. x, height in the scene, strength.
func whale(at date: Date) -> SIMD3<Float> {
    let block = 47.0
    let minutes = date.timeIntervalSince1970 / 60
    let index = (minutes / block).rounded(.down)
    var random = scrambled(Int(index), seed: 7)
    guard random.next() < 0.2 else { return .zero }
    let seconds = (minutes - index * block - random.next() * (block - 1)) * 60
    let x = 0.1 + 0.8 * random.next(), below = 0.01 + 0.01 * random.next()
    guard seconds >= 0, seconds < 40 else { return .zero }
    return SIMD3(Float(x), Float(horizonFraction - below), Float(smooth(0, 8, seconds) * (1 - smooth(12, 40, seconds))))
}

// Only when rain and a low sun coincide, as with a real one.
func rainbowStrength(_ weather: Weather, sunAltitude: Double, date: Date) -> Double {
    smooth(0.68, 0.8, drifting(date.timeIntervalSince1970 / 3600 / 2, seed: 8))
        * smooth(0.15, 0.6, weather.rain) * smooth(0.02, 0.1, sunAltitude) * (1 - smooth(0.5, 0.7, sunAltitude))
        * (1 - 0.5 * smooth(0.6, 1, weather.cover)) * (1 - weather.fog)
}

// Colour by solar altitude. Daylight is held dim and grey on purpose: a bright sky on a second
// screen pulls the eye as much as motion does.
private func colour(_ hex: UInt32) -> SIMD3<Float> {
    SIMD3(Float((hex >> 16) & 255), Float((hex >> 8) & 255), Float(hex & 255)) / 255
}

private let palette: [(alt: Double, colours: [SIMD3<Float>])] = [
    // altitude, sky top, horizon, sea far, sea near, glow
    (-90, [0x05070d, 0x090d17, 0x070a11, 0x030408, 0x000000]),
    (-18, [0x05070d, 0x0b101b, 0x080b13, 0x030408, 0x05060c]),
    (-12, [0x0a1020, 0x181f33, 0x0f1422, 0x05070d, 0x1c1826]),
    (-6, [0x141b33, 0x453644, 0x262333, 0x0a0c15, 0x5a3238]),
    (-1, [0x232d4b, 0x7d4c3b, 0x4a3435, 0x10121d, 0x8a4526]),
    (3, [0x303b54, 0x96694d, 0x655045, 0x161a26, 0xa56435]),
    (10, [0x3a475c, 0x7d7468, 0x585c5e, 0x1c2632, 0x6d5337]),
    (30, [0x3e4c60, 0x6b7377, 0x515e65, 0x212d38, 0x3f3b33]),
    (90, [0x3b4c60, 0x6f7a80, 0x55636b, 0x24313b, 0x3a3a35]),
].map { (alt: $0.0, colours: $0.1.map(colour)) }

func paletteAt(altitude: Double) -> [SIMD3<Float>] {
    var i = 0
    while i < palette.count - 2, altitude > palette[i + 1].alt { i += 1 }
    let a = palette[i], b = palette[i + 1]
    let k = Float(min(1, max(0, (altitude - a.alt) / (b.alt - a.alt))))
    return zip(a.colours, b.colours).map { $0 + ($1 - $0) * k }
}
