import simd

struct DrawItem {
    var model: float4x4
    var color: float4
    var isSphere = false
    var material = 0          // see Material enum in Shaders.metal
    var spec: Float = 0.05
    var castsShadow = true
    var prevModel: float4x4? = nil     // filled in by the Renderer (previous frame's transform, for motion vectors)
    var part: Int? = nil          // Blender-authored mesh id (PartID.rawValue)
    var accent = float4(1, 1, 1, 1)   // secondary colour (collar, stripes, headband…)
    var rough: Float = 0.6
}

/// Builds the per-frame draw list from game state (court, stadium, net, player, ball).
enum SceneBuilder {
    static func box(_ c: float3, _ s: float3, _ col: float4, mat: Int = 0, spec: Float = 0.05, shadow: Bool = true) -> DrawItem {
        DrawItem(model: .translation(c) * .scale(s), color: col, material: mat, spec: spec, castsShadow: shadow)
    }
    static func ball(_ c: float3, _ s: float3, _ col: float4, spec: Float = 0.2) -> DrawItem {
        DrawItem(model: .translation(c) * .scale(s), color: col, isSphere: true, spec: spec)
    }

    static func build(game: GameState, skinnedPlayers: Bool = false) -> [DrawItem] {
        var items: [DrawItem] = []
        let white = float4(0.93, 0.93, 0.93, 1)
        let L = Court.halfLength, W = Court.halfWidthDoubles, S = Court.halfWidthSingles

        // Sky dome
        items.append(DrawItem(model: .scale(float3(repeating: 2400)), color: float4(1, 1, 1, 1), isSphere: true, material: 4, castsShadow: false))
        // Ground, surround, court
        let surf = CourtSurface.current
        let groundCol: float4 = surf == .clay ? float4(0.17, 0.30, 0.15, 1) : float4(0.20, 0.36, 0.20, 1)
        items.append(box(float3(0, -0.5, 0), float3(400, 1.0, 400), groundCol, mat: 2, shadow: false))
        func court(_ c: float3, _ sz: float3, _ col: float4, spec: Float) -> DrawItem {
            var it = box(c, sz, col, mat: 1, spec: spec); it.accent = float4(1, 1, 1, Float(surf.rawValue)); return it   // accent.w = surface id
        }
        let sp: Float = surf == .hard ? 0.1 : 0.03
        items.append(court(float3(0, -0.01, 0), float3(2 * (W + 3.8), 0.03, 2 * (L + 6.4)), surf.surroundColor, spec: sp))
        items.append(court(float3(0, 0.0, 0), float3(2 * W, 0.04, 2 * L), surf.courtColor, spec: surf == .hard ? 0.12 : 0.03))

        // Lines
        func lineBox(_ c: float3, _ sz: float3, _ col: float4, spec: Float, shadow: Bool) -> DrawItem {
            var it = box(c, sz, col, mat: 1, spec: spec, shadow: shadow); it.accent = float4(1, 1, 1, 3); return it       // accent.w = 3: court line
        }
        let lw: Float = 0.055, ly: Float = 0.022
        for x in [-W, W, -S, S] { items.append(lineBox(float3(x, ly, 0), float3(lw, 0.012, 2 * L), white, spec: 0.1, shadow: false)) }
        for z in [-L, L] { items.append(lineBox(float3(0, ly, z), float3(2 * W, 0.012, lw), white, spec: 0.1, shadow: false)) }
        for z in [-Court.serviceLineZ, Court.serviceLineZ] { items.append(lineBox(float3(0, ly, z), float3(2 * S, 0.012, lw), white, spec: 0.1, shadow: false)) }
        items.append(lineBox(float3(0, ly, 0), float3(lw, 0.012, 2 * Court.serviceLineZ), white, spec: 0.1, shadow: false))
        for z in [-L, L] { items.append(lineBox(float3(0, ly, z - (z > 0 ? -0.1 : 0.1)), float3(0.1, 0.012, 0.2), white, spec: 0.1, shadow: false)) }

        // Net, tape, posts, center strap
        items.append(box(float3(0, Court.netHeightCenter / 2 + 0.02, 0), float3(2 * Court.netHalfWidth, Court.netHeightCenter - 0.04, 0.02), float4(0.04, 0.04, 0.05, 1), mat: 5, shadow: false))
        items.append(box(float3(0, Court.netHeightCenter, 0), float3(2 * Court.netHalfWidth, 0.07, 0.04), white))
        items.append(box(float3(0, 0.25, 0), float3(0.05, 0.5, 0.03), white))
        for x in [-Court.netHalfWidth - 0.1, Court.netHalfWidth + 0.1] {
            items.append(box(float3(x, Court.netHeightPost / 2, 0), float3(0.1, Court.netHeightPost, 0.1), float4(0.08, 0.08, 0.09, 1), spec: 0.5))
        }
        // Umpire chair + umpire
        items.append(box(float3(-W - 1.4, 1.35, 0), float3(0.15, 2.7, 0.15), float4(0.55, 0.55, 0.58, 1), spec: 0.4))
        items.append(box(float3(-W - 1.4, 2.7, 0), float3(0.8, 0.12, 0.8), float4(0.1, 0.1, 0.12, 1)))
        items.append(box(float3(-W - 1.4, 3.15, 0), float3(0.4, 0.7, 0.3), float4(0.1, 0.2, 0.5, 1)))
        items.append(ball(float3(-W - 1.4, 3.65, 0), float3(repeating: 0.24), float4(0.85, 0.65, 0.5, 1)))
        // Ball kids' benches and bins
        for s: Float in [-1, 1] {
            items.append(box(float3(W + 2.2, 0.25, s * 6), float3(0.5, 0.5, 2), float4(0.1, 0.15, 0.35, 1)))
        }

        // Stadium bowl: stepped tiers with seat rows (spectators are GPU-instanced separately), vertical risers, advertising boards, back walls
        let concrete = float4(0.42, 0.42, 0.44, 1), seat = float4(0.2, 0.2, 0.26, 1)
        let tiers = Stadium.tiers
        for tier in 0..<tiers {
            let (dz, dx, h) = Stadium.tier(tier)       // same dimensions the crowd is seated on (see CrowdBuilder)
            for s: Float in [-1, 1] {
                // top surfaces carry the crowd; boxes are solid so risers are concrete-coloured by normal
                items.append(box(float3(0, h / 2, s * dz), float3(2 * (dx + 1.5), h, 1.5), tier == 0 ? concrete : seat, mat: 3, spec: 0.02))
                items.append(box(float3(s * dx, h / 2, 0), float3(1.5, h, 2 * (dz - 0.75)), tier == 0 ? concrete : seat, mat: 3, spec: 0.02))
            }
        }
        // Upper rim + back wall
        let rimZ = L + 8.5 + Float(tiers) * Stadium.tierDepth, rimX = W + 7.5 + Float(tiers) * Stadium.tierDepth
        for s: Float in [-1, 1] {
            items.append(box(float3(0, 11, s * rimZ), float3(2 * (rimX + 1.5), 4, 0.6), concrete))
            items.append(box(float3(s * rimX, 11, 0), float3(0.6, 4, 2 * rimZ), concrete))
        }
        // Stadium roof: sloped canopy panels over the upper tiers, steel trusses, lighting rigs and tunnel mouths.
        // The panels cast shadows into the far shadow cascade, so they shade the crowd below.
        func slab(_ c: float3, _ size: float3, rotX: Float = 0, rotZ: Float = 0, col: float4, mat: Int = 0, spec: Float = 0.1, shadow: Bool = true) -> DrawItem {
            DrawItem(model: .translation(c) * .rotationX(rotX) * .rotationZ(rotZ) * .scale(size), color: col, material: mat, spec: spec, castsShadow: shadow)
        }
        let roofCol = float4(0.30, 0.31, 0.34, 1), steel = float4(0.16, 0.17, 0.19, 1)
        let innerZ = L + 8.5 + 4 * Stadium.tierDepth, innerX = W + 7.5 + 4 * Stadium.tierDepth      // roof starts above tier 4
        let depthZ = rimZ + 1.0 - innerZ, depthX = rimX + 1.0 - innerX
        let slope: Float = 0.10
        for sgn: Float in [-1, 1] {
            // end canopies (±z): inner edge low, rising toward the outer wall
            items.append(slab(float3(0, 12.6 + 0.4, sgn * (innerZ + depthZ / 2)), float3(2 * (rimX + 1.0), 0.35, depthZ), rotX: sgn * -slope, col: roofCol, mat: 13))
            // side canopies (±x)
            items.append(slab(float3(sgn * (innerX + depthX / 2), 12.75 + 0.4, 0), float3(depthX, 0.35, 2 * (rimZ - 4.0)), rotZ: sgn * slope, col: roofCol, mat: 13))
            // trusses under the canopies, every 4 m
            var t: Float = -rimX
            while t <= rimX {
                items.append(slab(float3(t, 12.15 + 0.4, sgn * (innerZ + depthZ / 2)), float3(0.22, 0.45, depthZ), rotX: sgn * -slope, col: steel))
                t += 4
            }
            var u: Float = -(rimZ - 4.0)
            while u <= rimZ - 4.0 {
                items.append(slab(float3(sgn * (innerX + depthX / 2), 12.3 + 0.4, u), float3(depthX, 0.45, 0.22), rotZ: sgn * slope, col: steel))
                u += 4
            }
            // inner edge beams + lighting rigs hanging from them (emissive: HDR, they bloom)
            items.append(slab(float3(0, 12.0, sgn * innerZ), float3(2 * (rimX + 1.0), 0.6, 0.5), col: steel))
            items.append(slab(float3(sgn * innerX, 12.15, 0), float3(0.5, 0.6, 2 * (rimZ - 4.0)), col: steel))
            var lx: Float = -rimX + 3
            while lx <= rimX - 3 {
                items.append(slab(float3(lx, 11.55, sgn * (innerZ - 0.4)), float3(1.4, 0.35, 0.5), col: float4(1, 0.97, 0.88, 1), mat: 6, shadow: false))
                lx += 3.2
            }
            var lz: Float = -(rimZ - 7)
            while lz <= rimZ - 7 {
                items.append(slab(float3(sgn * (innerX - 0.4), 11.7, lz), float3(0.5, 0.35, 1.4), col: float4(1, 0.97, 0.88, 1), mat: 6, shadow: false))
                lz += 3.2
            }
            // tunnel mouths in the end-stand risers
            for tx: Float in [-9, 9] {
                let (dz2, _, h2) = Stadium.tier(2)
                items.append(slab(float3(tx, h2 - 0.2, sgn * (dz2 - 0.72)), float3(3.2, 2.2, 0.2), col: float4(0.01, 0.01, 0.012, 1), shadow: false))
                items.append(slab(float3(tx, h2 + 0.95, sgn * (dz2 - 0.7)), float3(3.8, 0.25, 0.3), col: float4(0.85, 0.85, 0.9, 1), shadow: false))
            }
        }
        // Players' benches (towels + coolers) beside the umpire chair side
        for bz: Float in [-3.2, 3.2] {
            items.append(box(float3(W + 3.0, 0.28, bz), float3(0.6, 0.12, 2.0), float4(0.12, 0.14, 0.2, 1)))
            items.append(box(float3(W + 3.3, 0.55, bz), float3(0.1, 0.55, 2.0), float4(0.12, 0.14, 0.2, 1)))
            items.append(box(float3(W + 3.0, 0.34, bz + 0.6), float3(0.5, 0.06, 0.4), float4(0.95, 0.95, 0.95, 1)))     // towel
            items.append(box(float3(W + 3.2, 0.38, bz - 1.5), float3(0.3, 0.55, 0.3), float4(0.1, 0.25, 0.7, 1), spec: 0.3))   // cooler
        }

        // Advertising boards ringing the court
        let ad = float4(0.06, 0.12, 0.35, 1)
        for s: Float in [-1, 1] {
            items.append(box(float3(0, 0.55, s * (L + 6.6)), float3(2 * (W + 4.4), 1.1, 0.25), ad, mat: 8, spec: 0.3))
            items.append(box(float3(s * (W + 4.2), 0.55, 0), float3(0.25, 1.1, 2 * (L + 6.6)), ad, mat: 8, spec: 0.3))
        }
        // Scoreboards on the far stand and floodlight towers at the corners
        // Scoreboard (10 × 2.4 m, face toward the court) with support posts; its content is a live CoreText texture.
        items.append(box(float3(0, 5.5, -(L + 8.2 + 0.1)), float3(10.4, 2.8, 0.3), float4(0.03, 0.03, 0.04, 1), spec: 0.3))
        items.append(box(float3(0, 5.5, -(L + 8.2 + 0.1) + 0.16), float3(10, 2.4, 0.02), float4(1, 1, 1, 1), mat: 9, shadow: false))
        for x: Float in [-4.2, 4.2] { items.append(box(float3(x, 2.4, -(L + 8.2 + 0.1)), float3(0.25, 4.8, 0.25), float4(0.3, 0.3, 0.33, 1), spec: 0.3)) }
        for sx: Float in [-1, 1] { for sz: Float in [-1, 1] {
            let px = sx * (W + 9), pz = sz * (L + 9)
            items.append(box(float3(px, 9, pz), float3(0.5, 18, 0.5), float4(0.3, 0.3, 0.33, 1), spec: 0.3))
            items.append(box(float3(px, 18.5, pz), float3(4, 2, 0.6), float4(1, 0.97, 0.85, 1), mat: 6, shadow: false))
        } }

        // Players: Blender-authored parts posed by the animation rig; the shader adds faces, collars, cuffs, socks and soles.
        func drawPlayer(_ p: Player, shirt: float4, shorts: float4, hair: float4, accent: float4) {
            let rig = CharacterRig.evaluate(world: p.worldMatrix, pose: p.anim.pose)
            let racketIDs: Set<PartID> = [.racketHandle, .racketFrame, .racketStrings]
            for (id, m) in rig.parts {
                if skinnedPlayers && !racketIDs.contains(id) { continue }       // the skinned athlete replaces the rigid body parts
                var col = float4(1, 1, 1, 1), spec: Float = 0.05
                switch id {
                case .torso, .upperArm: col = shirt
                case .shorts: col = shorts
                case .hair: col = hair
                case .racketFrame: spec = 0.5
                case .racketHandle: spec = 0.1
                default: break
                }
                items.append(DrawItem(model: m, color: col, material: 11, spec: spec, part: id.rawValue, accent: accent))
            }
        }
        drawPlayer(game.player, shirt: float4(0.96, 0.96, 0.96, 1), shorts: float4(0.08, 0.14, 0.40, 1), hair: float4(0.08, 0.06, 0.05, 1), accent: float4(0.10, 0.25, 0.75, 1))
        drawPlayer(game.opponent, shirt: float4(0.85, 0.15, 0.12, 1), shorts: float4(0.10, 0.10, 0.12, 1), hair: float4(0.55, 0.38, 0.12, 1), accent: float4(0.95, 0.95, 0.95, 1))

        // Ball: oversized for visibility (≈2.4× real), with a faint emissive-like bright colour
        let b = game.ball
        let br = Ball.radius * 2 * 2.4
        // Motion trail: fading balls along the recent path (fast shots only)
        for (i, p) in game.ballTrail.dropLast().enumerated() {
            let t = Float(i + 1) / Float(game.ballTrail.count)
            var tr = ball(p, float3(repeating: br * (0.35 + 0.5 * t)), float4(0.85, 1.0, 0.15, 1), spec: 0.0)
            tr.material = 6; tr.castsShadow = false; tr.color = float4(0.85 * t * 0.6, 1.0 * t * 0.6, 0.15 * t * 0.3, 1)
            items.append(tr)
        }
        var ballItem = ball(b.position, float3(repeating: br), float4(0.85, 1.0, 0.15, 1), spec: 0.05)
        ballItem.material = 12
        items.append(ballItem)
        // Bounce marks: clay shows a pale scuff ring that fades; grass shows a dark worn dot
        if CourtSurface.current != .hard {
            for m in game.ballMarks {
                let fade = max(0, 1 - m.age / 45)
                let clay = CourtSurface.current == .clay
                let col: float4 = clay ? float4(0.78 * (0.6 + 0.4 * fade), 0.55 * (0.6 + 0.4 * fade), 0.42, 1) : float4(0.30, 0.25, 0.14, 1)
                var mk = box(float3(m.pos.x, 0.0225, m.pos.z), float3(0.11, 0.001, 0.11), col, mat: 1, spec: 0, shadow: false)
                mk.accent = float4(1, 1, 1, 5); mk.rough = fade                                 // accent.w = 5: bounce mark (round, soft edge)
                items.append(mk)
            }
        }
        return items
    }
}
