import MetalKit
import simd

final class GPUTimeBox { var value = 0.0; let sem = DispatchSemaphore(value: 0) }

// Layouts mirrored by Shaders.metal (only float4 / float4x4 members, so Swift and MSL agree).
struct FrameUniforms {
    var viewProj: float4x4              // rasterisation matrix (jittered when MetalFX upscaling is active)
    var lightViewProj: float4x4
    var lightViewProj2: float4x4        // far shadow cascade (stadium)
    var viewProjUnjit: float4x4
    var prevViewProj: float4x4
    var lightDirTime: float4            // xyz sun direction, w time
    var camPosCheer: float4             // xyz camera, w crowd excitement
    var ballPosPrevTime: float4         // xyz ball, w previous-frame time
    var renderSizeJitter: float4        // xy render size, zw texel jitter
    var misc: float4                    // x = far cascade enabled
}
struct DrawUniforms { var model: float4x4; var prevModel: float4x4; var color: float4; var accent: float4; var params: float4 }

/// Per-frame values the post-processing passes need (depth linearisation, projection scale, focus).
struct PostInfo { var depthA: Float; var depthB: Float; var p00: Float; var p11: Float; var focusDist: Float }

/// Everything one frame needs, produced once by `Renderer.makeFrame` and consumed by either backend.
struct FrameData {
    var items: [DrawItem]
    var uniforms: FrameUniforms
    var pixelJitter: float2             // MetalFX jitterOffset (pixels, y already flipped)
    var resetHistory: Bool
    var post: PostInfo
    var characters: [SkinnedCharacterDraw] = []
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let crowdPipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let shadowPipeline: MTLRenderPipelineState
    let shadowMap: MTLTexture
    static let shadowSize = 3072
    static let sunDir = simd_normalize(float3(-0.45, -1, -0.35))
    let sky: Mesh
    let partMeshes: [Int: Mesh]
    let box: Mesh, sphere: Mesh
    let spectatorMesh: Mesh?
    let crowdBuffer: MTLBuffer?
    let crowdCount: Int
    let scoreboard: ScoreboardTexture
    let adTexture: AdTexture
    private(set) var athlete: AthleteModel?
    private var prevCharacters: [Float: (palette: [float4x4], model: float4x4)] = [:]
    let game: GameState
    let input: InputManager
    var camera = BroadcastCamera()
    var onHUD: ((String) -> Void)?
    var onGameEvent: ((GameEvent) -> Void)?       // audio, haptics…
    var onAnnouncement: ((String) -> Void)?      // umpire calls
    var onCrowdLevel: ((Float) -> Void)?
    var cameraMode: CameraMode = .broadcast
    /// Scripted camera (demo mode): returns eye / target / vertical fov for the current time.
    var cameraOverride: ((Float) -> (eye: float3, target: float3, fov: Float))?
    var showStats = true
    /// Fraction of the display resolution the scene is rendered at before MetalFX upscales it (Metal 4 path only).
    var renderScale: Float = 0.75
    private var lastTime = CACurrentMediaTime()
    private let startTime = CACurrentMediaTime()
    private var smoothedFrameMs: Double = 16
    private(set) var gpuMs: Double = 0

    // Temporal state for motion vectors / jitter.
    private var prevViewProj = matrix_identity_float4x4
    private var prevItems: [DrawItem] = []
    private var prevTime: Float = 0
    private var jitterIndex: UInt32 = 0
    private var lastRenderSize = CGSize.zero
    var resetHistory = true
    private var focusDist: Float = 25

    /// nil when the GPU lacks Metal 4 (or TS_METAL3 is set): rendering then uses the classic command-buffer path.
    private(set) var backend: Metal4Backend?
    private(set) var classicHDR: ClassicHDR?
    var backendName: String { backend != nil ? "Metal 4 + MetalFX" : "Metal HDR" }

    init?(view: MTKView, game: GameState, input: InputManager, forceClassic: Bool = ProcessInfo.processInfo.environment["TS_METAL3"] != nil) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(),
              let lib = dev.makeDefaultLibrary() else { return nil }
        device = dev; queue = q; self.game = game; self.input = input
        #if targetEnvironment(simulator)
        let wantMetal4 = false
        #else
        let wantMetal4 = !forceClassic && dev.supportsFamily(.metal4)
        #endif
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm_srgb
        // Metal 4 path renders the scene into its own HDR targets and composites to the (single-sample, depth-less) drawable.
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.clearColor = MTLClearColor(red: 0.45, green: 0.62, blue: 0.85, alpha: 1)

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride
        func classicPipeline(_ vs: String) -> MTLRenderPipelineState? {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: vs)
            pd.fragmentFunction = lib.makeFunction(name: "fs_main")
            pd.vertexDescriptor = vd
            pd.rasterSampleCount = 4
            pd.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pd.depthAttachmentPixelFormat = .depth32Float
            return try? dev.makeRenderPipelineState(descriptor: pd)
        }
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less; dd.isDepthWriteEnabled = true
        guard let ps = classicPipeline("vs_main"), let cps = classicPipeline("vs_crowd"),
              let ds = dev.makeDepthStencilState(descriptor: dd) else { return nil }
        // Depth-only pipeline for the sun shadow map.
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = lib.makeFunction(name: "vs_main")
        sd.vertexDescriptor = vd
        sd.depthAttachmentPixelFormat = .depth32Float
        let classicShadowSize = wantMetal4 ? 4 : Renderer.shadowSize          // Metal 4 owns its per-slot maps
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: classicShadowSize, height: classicShadowSize, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        guard let sps = try? dev.makeRenderPipelineState(descriptor: sd), let sm = dev.makeTexture(descriptor: td) else { return nil }
        shadowPipeline = sps; shadowMap = sm
        pipeline = ps; crowdPipeline = cps; depthState = ds
        box = Mesh.unitBox(device: dev); sphere = Mesh.unitSphere(device: dev); sky = Mesh.unitSphere(device: dev, stacks: 24, slices: 48)
        partMeshes = PartID.loadAll(device: dev)
        if let url = Bundle.main.url(forResource: "spectator", withExtension: "obj"), let m = OBJLoader.load(device: dev, url: url),
           let (buf, n) = CrowdBuilder.buffer(device: dev) {
            spectatorMesh = m; crowdBuffer = buf; crowdCount = n
        } else { NSLog("Crowd assets missing; audience disabled"); spectatorMesh = nil; crowdBuffer = nil; crowdCount = 0 }
        guard let sb = ScoreboardTexture(device: dev), let adt = AdTexture(device: dev) else { return nil }
        scoreboard = sb; adTexture = adt
        if let url = Bundle.main.url(forResource: "athlete", withExtension: "hum") { athlete = AthleteModel(device: dev, url: url) }
        if athlete == nil { NSLog("Skinned athlete asset missing; using rigid fallback") }
        if !wantMetal4 { classicHDR = ClassicHDR(device: dev, library: lib, vertexDescriptor: vd) }
        if wantMetal4 {
            backend = Metal4Backend(device: dev, library: lib, vertexDescriptor: vd, shadowSize: Renderer.shadowSize)
            var meshes = [box, sphere, sky] + Array(partMeshes.values)
            if let m = spectatorMesh { meshes.append(m) }
            var allocs: [MTLAllocation] = meshes.flatMap { [$0.vertexBuffer, $0.indexBuffer] } + [sb.texture, adt.texture] + (athlete?.allBuffers ?? [])
            if let b = crowdBuffer { allocs.append(b) }
            backend?.makeResident(allocs)
        }
        super.init()
        view.delegate = self
        #if !targetEnvironment(simulator)
        if let b = backend, #available(macOS 26.4, iOS 26.4, *) {        // keep the view's drawable textures resident
            b.addResidencySet(view.residencySet)
            if let l = view.layer as? CAMetalLayer { b.addResidencySet(l.residencySet) }
        }
        #endif
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { resetHistory = true }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 0.1)); lastTime = now
        smoothedFrameMs = smoothedFrameMs * 0.95 + Double(dt) * 1000 * 0.05
        game.update(frameDt: dt, input: input.poll())
        for e in game.events { onGameEvent?(e) }
        game.events.removeAll(keepingCapacity: true)
        if let a = game.announcement { onAnnouncement?(a); game.announcement = nil }
        onCrowdLevel?(game.crowdExcitement)
        let serveCam = (game.phase == .serveReady || game.phase == .tossed) && game.server > 0
        camera.update(mode: cameraMode, player: game.player, ball: game.ball, dt: dt, serveCam: serveCam)
        if let o = cameraOverride { let c = o(Float(CACurrentMediaTime() - startTime)); camera.eye = c.eye; camera.target = c.target; camera.fov = c.fov }
        camera.setShake(game.shake, time: Float(CACurrentMediaTime() - startTime))
        let gpuUpdate: (Double) -> Void = { [weak self] g in
            if g > 0 { self?.gpuMs = (self?.gpuMs ?? g) * 0.95 + g * 0.05 }
        }

        #if !targetEnvironment(simulator)
        if let b = backend {
            if let pass = view.currentMTL4RenderPassDescriptor, let drawable = view.currentDrawable {
                let display = view.drawableSize
                let f = makeFrame(displaySize: display)
                b.render(frame: f, displaySize: display, renderScale: effectiveScale, board: scoreboard.texture, ads: adTexture.texture, mesh: { [unowned self] in mesh(for: $0) },
                         crowd: crowdDraw, finalPass: pass, drawable: drawable, gpuTime: gpuUpdate)
            }
            updateHUD()
            return
        }
        #endif
        if let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() {
            encodeScene(cb: cb, pass: pass, size: view.drawableSize)
            cb.addCompletedHandler { c in gpuUpdate((c.gpuEndTime - c.gpuStartTime) * 1000) }
            cb.present(drawable)
            cb.commit()
        }
        updateHUD()
    }

    private func updateHUD() {
        let speed = simd_length(game.ball.velocity) * 3.6
        var text = "\(game.scoreText)\n\(game.lastEvent)"
        if showStats {
            let scale = backend != nil ? String(format: " · render %.0f%%", effectiveScale * 100) : ""
            text += String(format: "\nBall %.0f km/h · spin %.0f rad/s · cam %@ · %@\n%.1f ms/frame · GPU %.2f ms · %@ (%@)%@ · crowd %d",
                           speed, simd_length(game.ball.spin), cameraMode.rawValue, game.difficulty.name, smoothedFrameMs, gpuMs,
                           device.name, backendName, scale, crowdCount)
        }
        #if os(iOS)
        text += "\nLeft side: drag to move · SWING: toss / topspin · SLICE · LOB · DROP · ☰ menu"
        #else
        text += "\nWASD/arrows move · SPACE topspin (toss/serve) · J slice · K lob · L drop shot · R new match · C camera · ESC menu"
        #endif
        onHUD?(text)
    }

    var effectiveScale: Float { simd_clamp(renderScale, 0.5, 1.0) }

    func mesh(for item: DrawItem) -> Mesh? {
        if item.material == 4 { return sky }
        if let id = item.part { return partMeshes[id] }
        return item.isSphere ? sphere : box
    }

    var crowdDraw: (mesh: Mesh, buffer: MTLBuffer, count: Int)? {
        guard let m = spectatorMesh, let b = crowdBuffer, crowdCount > 0 else { return nil }
        return (m, b, crowdCount)
    }

    private func halton(_ index: UInt32, _ base: UInt32) -> Float {
        var f: Float = 1, r: Float = 0, i = index
        while i > 0 { f /= Float(base); r += f * Float(i % base); i /= base }
        return r
    }

    /// Builds the draw list and frame uniforms (camera, sun shadow projection, jitter, previous-frame matrices) for both
    /// backends. With Metal 4 the render size is smaller than the display size and a Halton jitter is applied for MetalFX.
    func makeFrame(displaySize: CGSize) -> FrameData {
        let upscaling = backend != nil
        let size = upscaling ? Metal4Backend.renderSize(display: displaySize, scale: effectiveScale) : displaySize
        if size != lastRenderSize { lastRenderSize = size; resetHistory = true }
        let aspect = Float(size.width / max(size.height, 1))
        scoreboard.update(game: game)
        let skinned = athlete != nil
        var items = SceneBuilder.build(game: game, skinnedPlayers: skinned)
        for i in items.indices { items[i].prevModel = i < prevItems.count ? prevItems[i].model : items[i].model }

        // Sun view-projection: orthographic box around the court (Metal depth 0…1).
        let lightView = float4x4.lookAt(eye: -Renderer.sunDir * 70, target: float3(0, 0, 0))
        let (hx, hy, n, fz): (Float, Float, Float, Float) = (24, 30, 1, 160)
        let ortho = float4x4(columns: (float4(1 / hx, 0, 0, 0), float4(0, 1 / hy, 0, 0), float4(0, 0, -1 / (fz - n), 0), float4(0, 0, -n / (fz - n), 1)))
        let lightVP = ortho * lightView
        let (hx2, hy2): (Float, Float) = (68, 78)                          // far cascade covers the whole bowl and roof
        let ortho2 = float4x4(columns: (float4(1 / hx2, 0, 0, 0), float4(0, 1 / hy2, 0, 0), float4(0, 0, -1 / (200 - n), 0), float4(0, 0, -n / (200 - n), 1)))
        let lightVP2 = ortho2 * float4x4.lookAt(eye: -Renderer.sunDir * 90, target: float3(0, 0, 0))

        // MetalFX jitter (Halton 2,3), following Apple's sample: shift the projection, keep the unjittered matrix for motion.
        var proj = camera.projection(aspect: aspect)
        var pixelJitter = float2.zero, texelJitter = float2.zero
        if upscaling {
            if resetHistory { jitterIndex = 0 }
            jitterIndex += 1
            let idx = (jitterIndex - 1) % 32 + 1
            var pj = float2(halton(idx, 2) - 0.5, halton(idx, 3) - 0.5)
            let rs = float2(Float(size.width), Float(size.height))
            let ndc = -2 * pj / rs
            pj.y = -pj.y
            pixelJitter = pj; texelJitter = pj / rs
            proj.columns.2[0] += ndc.x; proj.columns.2[1] += ndc.y
        }
        let viewM = camera.view
        let unjit = camera.projection(aspect: aspect) * viewM
        let time = Float(CACurrentMediaTime() - startTime)
        let fu = FrameUniforms(viewProj: proj * viewM, lightViewProj: lightVP, lightViewProj2: lightVP2, viewProjUnjit: unjit, prevViewProj: resetHistory ? unjit : prevViewProj,
                               lightDirTime: float4(Renderer.sunDir, time),
                               camPosCheer: float4(camera.eye, game.crowdExcitement),
                               ballPosPrevTime: float4(game.ball.position, resetHistory ? time : prevTime),
                               renderSizeJitter: float4(Float(size.width), Float(size.height), texelJitter.x, texelJitter.y),
                               misc: float4(1, 0, 0, 0))
        // Depth-of-field focus follows the action: the point between the human player and the ball, smoothed.
        let focusTarget = simd_distance(camera.eye, (game.player.position + game.ball.position) * 0.5 + float3(0, 1, 0))
        focusDist += (focusTarget - focusDist) * (resetHistory ? 1 : 0.08)
        let up = camera.projection(aspect: aspect)
        let post = PostInfo(depthA: up.columns.2[2], depthB: up.columns.3[2], p00: up.columns.0[0], p11: up.columns.1[1], focusDist: focusDist)
        var frame = FrameData(items: items, uniforms: fu, pixelJitter: pixelJitter, resetHistory: resetHistory, post: post)
        if skinned, let a = athlete { frame.characters = [buildCharacter(game.player, a, style: .home), buildCharacter(game.opponent, a, style: .away)] }
        prevViewProj = unjit; prevItems = items; prevTime = time; resetHistory = false
        return frame
    }

    // MARK: Skinned athletes

    struct AthleteStyle {
        var skin: float4, hair: float4, iris: float4, shirt: float4, accent: float4, shorts: float4, shortsAccent: float4
        static let home = AthleteStyle(skin: float4(0.80, 0.58, 0.44, 1), hair: float4(0.08, 0.06, 0.05, 1), iris: float4(0.30, 0.19, 0.10, 1),
                                       shirt: float4(0.96, 0.96, 0.96, 1), accent: float4(0.10, 0.25, 0.75, 1),
                                       shorts: float4(0.08, 0.14, 0.40, 1), shortsAccent: float4(0.95, 0.95, 0.95, 1))
        static let away = AthleteStyle(skin: float4(0.93, 0.74, 0.62, 1), hair: float4(0.55, 0.38, 0.12, 1), iris: float4(0.22, 0.42, 0.62, 1),
                                       shirt: float4(0.85, 0.15, 0.12, 1), accent: float4(0.95, 0.95, 0.95, 1),
                                       shorts: float4(0.10, 0.10, 0.12, 1), shortsAccent: float4(0.85, 0.15, 0.12, 1))
    }

    /// Poses one athlete: bone palette from the animation rig, expression morphs, per-part materials.
    private func buildCharacter(_ p: Player, _ a: AthleteModel, style st: AthleteStyle) -> SkinnedCharacterDraw {
        let rig = CharacterRig.evaluate(world: p.worldMatrix, pose: p.anim.pose)
        let palette = CharacterRig.palette(frames: rig.frames, model: a, expression: p.expression)
        let model = p.worldMatrix * float4x4.scale(float3(repeating: CharacterRig.scale))
        let prev = resetHistory ? nil : prevCharacters[p.side]
        prevCharacters[p.side] = (palette, model)
        func part(_ name: String, _ mat: Int, _ color: float4, accent: float4 = float4(1, 1, 1, 0), cull: Bool = true, shadow: Bool = true,
                  rough: Float = 0.6, spec: Float = 0.05) -> SkinnedCharacterDraw.PartDraw? {
            guard let sp = a.parts[name] else { return nil }
            return .init(part: sp, material: mat, color: color, accent: accent, cullBack: cull, castsShadow: shadow, rough: rough, spec: spec)
        }
        func tag(_ c: float4, _ type: Float) -> float4 { var v = c; v.w = type; return v }
        let parts: [SkinnedCharacterDraw.PartDraw] = [
            part("body", 14, st.skin), part("eyes", 15, st.iris, shadow: false), part("hair", 16, st.hair, cull: false, shadow: false),
            part("brows", 16, st.hair, cull: false, shadow: false), part("lashes", 16, st.hair, cull: false, shadow: false),
            part("shirt", 17, st.shirt, accent: tag(st.accent, 0)), part("shorts", 17, st.shorts, accent: tag(st.shortsAccent, 1)),
            part("socks", 17, float4(0.9, 0.9, 0.9, 1), accent: tag(st.accent, 2), shadow: false), part("shoes", 17, float4(0.9, 0.9, 0.9, 1), accent: tag(st.accent, 3)),
            part("bands", 17, st.accent, accent: tag(st.accent, 4), shadow: false),
        ].compactMap { $0 }
        return SkinnedCharacterDraw(palette: palette, prevPalette: prev?.palette ?? palette, model: model, prevModel: prev?.model ?? model,
                                    morph: p.expression.vector, parts: parts)
    }

    // MARK: Classic (non-Metal-4) path

    func encodeScene(cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize) {
        let frame = makeFrame(displaySize: size)
        classicHDR?.encode(cb: cb, frame: frame, finalPass: pass, size: size, r: self)
    }

    func draw(_ item: DrawItem, on enc: MTLRenderCommandEncoder) {
        var du = DrawUniforms(model: item.model, prevModel: item.prevModel ?? item.model, color: item.color, accent: item.accent,
                              params: float4(Float(item.material), item.spec, item.rough, Float(item.part ?? 0)))
        guard let m = mesh(for: item) else { return }
        enc.setVertexBuffer(m.vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: m.indexCount, indexType: .uint16,
                                  indexBuffer: m.indexBuffer, indexBufferOffset: 0)
    }

    // MARK: Offscreen rendering (snapshot + benchmark)

    struct Targets { var resolve: MTLTexture; var color: MTLTexture?; var depth: MTLTexture?; var width: Int; var height: Int }

    func makeTargets(width: Int, height: Int) -> Targets {
        func tex(_ fmt: MTLPixelFormat, ms: Bool, usage: MTLTextureUsage) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: width, height: height, mipmapped: false)
            d.textureType = ms ? .type2DMultisample : .type2D
            if ms { d.sampleCount = 4 }
            d.usage = usage; d.storageMode = ms ? .private : .shared
            return device.makeTexture(descriptor: d)!
        }
        let resolve = tex(.bgra8Unorm_srgb, ms: false, usage: [.renderTarget, .shaderRead])
        backend?.makeResident([resolve])                          // both backends composite straight into the single-sample target
        return Targets(resolve: resolve, color: nil, depth: nil, width: width, height: height)
    }

    private func passDescriptor(_ t: Targets) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t.resolve
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        return pass
    }

    #if !targetEnvironment(simulator)
    private func finalPass4(_ t: Targets) -> MTL4RenderPassDescriptor {
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = t.resolve
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        return pass
    }
    #endif

    /// Renders one offscreen frame with whichever backend is active, waits for it, and returns (cpu encode+submit ms, gpu ms, wall ms).
    @discardableResult
    func renderOffscreen(_ t: Targets) -> (cpu: Double, gpu: Double, wall: Double)? {
        let size = CGSize(width: t.width, height: t.height)
        #if !targetEnvironment(simulator)
        if let b = backend {
            let box = GPUTimeBox()
            let t0 = CACurrentMediaTime()
            let f = makeFrame(displaySize: size)
            let v = b.render(frame: f, displaySize: size, renderScale: effectiveScale, board: scoreboard.texture, ads: adTexture.texture, mesh: { [unowned self] in mesh(for: $0) },
                             crowd: crowdDraw, finalPass: finalPass4(t), drawable: nil) { box.value = $0; box.sem.signal() }
            let t1 = CACurrentMediaTime()
            b.waitUntilCompleted(v)
            let t2 = CACurrentMediaTime()
            _ = box.sem.wait(timeout: .now() + 2)         // feedback arrives on a separate queue
            return ((t1 - t0) * 1000, box.value, (t2 - t0) * 1000)
        }
        #endif
        guard let cb = queue.makeCommandBuffer() else { return nil }
        let t0 = CACurrentMediaTime()
        encodeScene(cb: cb, pass: passDescriptor(t), size: size)
        let t1 = CACurrentMediaTime()
        cb.commit(); cb.waitUntilCompleted()
        let t2 = CACurrentMediaTime()
        return ((t1 - t0) * 1000, (cb.gpuEndTime - cb.gpuStartTime) * 1000, (t2 - t0) * 1000)
    }

    /// Pipelined throughput: submits `frames` frames back-to-back (up to 3 in flight, like the live app) and returns ms/frame.
    func throughput(frames: Int, width: Int, height: Int) -> Double {
        let t = makeTargets(width: width, height: height)
        let size = CGSize(width: width, height: height)
        let inflight = DispatchSemaphore(value: 3)
        func submit(_ i: Int) {
            game.ball.position.x = sinf(Float(i) * 0.05) * 3
            #if !targetEnvironment(simulator)
            if let b = backend {
                b.render(frame: makeFrame(displaySize: size), displaySize: size, renderScale: effectiveScale, board: scoreboard.texture, ads: adTexture.texture, mesh: { [unowned self] in mesh(for: $0) },
                         crowd: crowdDraw, finalPass: finalPass4(t), drawable: nil, gpuTime: nil)
                return
            }
            #endif
            guard let cb = queue.makeCommandBuffer() else { return }
            inflight.wait()
            encodeScene(cb: cb, pass: passDescriptor(t), size: size)
            cb.addCompletedHandler { _ in inflight.signal() }
            cb.commit()
        }
        for i in 0..<20 { submit(i) }                       // warm-up
        if let b = backend { b.drain() } else { for _ in 0..<3 { inflight.wait() }; for _ in 0..<3 { inflight.signal() } }
        let t0 = CACurrentMediaTime()
        for i in 0..<frames { submit(i) }
        if let b = backend { b.drain() } else { for _ in 0..<3 { inflight.wait() }; for _ in 0..<3 { inflight.signal() } }   // restore count before dealloc
        return (CACurrentMediaTime() - t0) * 1000 / Double(frames)
    }

    func snapshotImage(width: Int = 1280, height: Int = 720) -> CGImage? {
        let t = makeTargets(width: width, height: height)
        resetHistory = true
        // MetalFX needs a few jittered frames of history to converge; the classic path needs just one.
        for _ in 0..<(backend != nil ? 16 : 1) { guard renderOffscreen(t) != nil else { return nil } }
        return image(from: t)
    }

    /// Reads a finished offscreen target back as a CGImage.
    func image(from t: Targets) -> CGImage? {
        let (width, height) = (t.width, t.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        t.resolve.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }   // BGRA -> RGBA
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    #if os(macOS)
    static func writePNG(_ img: CGImage, to path: String) -> Bool {
        guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Offscreen render to a PNG (no window / screen-recording permission needed). Used for verification.
    func snapshot(to path: String, width: Int = 1280, height: Int = 720) -> Bool {
        guard let img = snapshotImage(width: width, height: height) else { return false }
        return Renderer.writePNG(img, to: path)
    }
    #endif

    struct BenchResult { var cpuMs: [Double]; var gpuMs: [Double]; var wallMs: [Double]; var draws: Int; var tris: Int }

    /// Renders `frames` frames offscreen, timing CPU encode and GPU execution.
    func benchmark(frames: Int, width: Int, height: Int) -> BenchResult {
        let t = makeTargets(width: width, height: height)
        var cpu: [Double] = [], gpu: [Double] = [], wall: [Double] = []
        for i in 0..<(frames + 10) {
            game.ball.position.x = sinf(Float(i) * 0.05) * 3     // keep dynamic content changing
            guard let r = renderOffscreen(t) else { break }
            if i >= 10 { cpu.append(r.cpu); gpu.append(r.gpu); wall.append(r.wall) }  // skip warm-up
        }
        let items = SceneBuilder.build(game: game)
        var tris = items.reduce(0) { $0 + ((mesh(for: $1)?.indexCount ?? 0) / 3) }
        tris += (spectatorMesh?.indexCount ?? 0) / 3 * crowdCount
        return BenchResult(cpuMs: cpu, gpuMs: gpu, wallMs: wall, draws: items.count + (crowdCount > 0 ? 1 : 0), tris: tris)
    }
}
