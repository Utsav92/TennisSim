import Metal
import MetalKit
import QuartzCore

#if !targetEnvironment(simulator)   // the iOS Simulator SDK doesn't ship the Metal 4 / MetalFX-for-Metal-4 API; devices and macOS do
import MetalFX

/// Metal 4 rendering backend. Frame graph:
///   1. two sun shadow cascades (near court map + far stadium map, per-frame-slot textures)
///   2. scene pass at render resolution → HDR colour (rgba16f) + motion vectors (rg16f) + depth; the crowd is instanced
///   3. SSAO at half render resolution from the depth buffer, then a depth-aware blur
///   4. MetalFX temporal scaler (MTL4FXTemporalScaler): anti-aliasing + upscaling to display resolution
///   5. bloom: soft-threshold prefilter then three tent-filter downsamples
///   6. composite: depth of field + per-tap motion blur, sharpen, SSAO, bloom, grade, ACES, vignette → drawable / offscreen
/// Metal 4 specifics: explicit allocators/command buffer, argument tables holding GPU addresses (no setBytes),
/// residency sets, shared-event pacing, queue-level drawable sync and explicit inter-pass barriers.
final class Metal4Backend {
    static let framesInFlight = 3
    static let ringBytes = 512 * 1024              // per-frame uniform ring (≈ 150 draws × 2 passes × 256 B)
    /// Set when the temporal scaler can't be created; the backend then renders at native resolution without upscaling.
    nonisolated(unsafe) static var upscalerUnavailable = false

    static func renderSize(display: CGSize, scale: Float) -> CGSize {
        let s = upscalerUnavailable ? 1 : scale
        return CGSize(width: max(64, Int(Float(display.width) * s)), height: max(64, Int(Float(display.height) * s)))
    }

    /// Mirrors `PostParams` in Shaders.metal (five float4s).
    struct PostParams { var a: SIMD4<Float>; var b: SIMD4<Float>; var c: SIMD4<Float>; var d: SIMD4<Float>; var e: SIMD4<Float> }

    private struct SceneTargets {
        var key: [Int]
        var color: MTLTexture, motion: MTLTexture, depth: MTLTexture, upscaled: MTLTexture
        var bloom: [MTLTexture]
        var ao: [MTLTexture]                      // half-resolution SSAO + blurred copy
        var all: [MTLTexture] { [color, motion, depth, upscaled] + bloom + ao }
    }

    let device: MTLDevice
    let queue: MTL4CommandQueue
    private let allocators: [MTL4CommandAllocator]
    private let cmd: MTL4CommandBuffer
    private let event: MTLSharedEvent
    private var frame: UInt64 = 0
    private let compiler: MTL4Compiler
    private let table: MTL4ArgumentTable
    private let scenePipeline: MTLRenderPipelineState
    private let skinnedPipeline: MTLRenderPipelineState
    private let skinnedShadowPipeline: MTLRenderPipelineState
    private let crowdPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let bloomPrefilter: MTLRenderPipelineState
    private let bloomDown: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let shadowMaps: [MTLTexture]        // one per frame slot: no cross-frame hazard, so no GPU barrier is needed
    private let shadowMapsFar: [MTLTexture]     // second (far) cascade, same scheme
    private let ssaoPipeline: MTLRenderPipelineState
    private let ssaoBlurPipeline: MTLRenderPipelineState
    private let residency: MTLResidencySet
    private let rings: [MTLBuffer]
    private var targets: SceneTargets?
    private var scaler: MTL4FXTemporalScaler?

    init?(device: MTLDevice, library: MTLLibrary, vertexDescriptor: MTLVertexDescriptor, shadowSize: Int) {
        guard device.supportsFamily(.metal4) else { return nil }
        do {
            guard let q = device.makeMTL4CommandQueue(), let cb = device.makeCommandBuffer(),
                  let ev = device.makeSharedEvent() else { return nil }
            queue = q; cmd = cb; event = ev
            var al: [MTL4CommandAllocator] = []
            for _ in 0..<Self.framesInFlight { guard let a = device.makeCommandAllocator() else { return nil }; al.append(a) }
            allocators = al

            let comp = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            compiler = comp
            func fn(_ name: String) -> MTL4LibraryFunctionDescriptor {
                let d = MTL4LibraryFunctionDescriptor(); d.name = name; d.library = library; return d
            }
            func scenePSO(vertex: String) throws -> MTLRenderPipelineState {
                let pd = MTL4RenderPipelineDescriptor()
                pd.vertexFunctionDescriptor = fn(vertex); pd.fragmentFunctionDescriptor = fn("fs_hdr")
                pd.vertexDescriptor = vertexDescriptor; pd.rasterSampleCount = 1
                pd.colorAttachments[0].pixelFormat = .rgba16Float
                pd.colorAttachments[1].pixelFormat = .rg16Float
                return try comp.makeRenderPipelineState(descriptor: pd)
            }
            func postPSO(fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
                let pd = MTL4RenderPipelineDescriptor()
                pd.vertexFunctionDescriptor = fn("vs_fullscreen"); pd.fragmentFunctionDescriptor = fn(fragment)
                pd.rasterSampleCount = 1
                pd.colorAttachments[0].pixelFormat = format
                return try comp.makeRenderPipelineState(descriptor: pd)
            }
            scenePipeline = try scenePSO(vertex: "vs_main")
            crowdPipeline = try scenePSO(vertex: "vs_crowd")
            func skinnedPSO(shadow: Bool) throws -> MTLRenderPipelineState {            // no vertex descriptor: vertices are fetched manually
                let pd = MTL4RenderPipelineDescriptor()
                pd.vertexFunctionDescriptor = fn("vs_skinned"); pd.rasterSampleCount = 1
                if !shadow {
                    pd.fragmentFunctionDescriptor = fn("fs_hdr")
                    pd.colorAttachments[0].pixelFormat = .rgba16Float
                    pd.colorAttachments[1].pixelFormat = .rg16Float
                }
                return try comp.makeRenderPipelineState(descriptor: pd)
            }
            skinnedPipeline = try skinnedPSO(shadow: false)
            skinnedShadowPipeline = try skinnedPSO(shadow: true)
            let sd = MTL4RenderPipelineDescriptor()
            sd.vertexFunctionDescriptor = fn("vs_main"); sd.vertexDescriptor = vertexDescriptor; sd.rasterSampleCount = 1
            shadowPipeline = try comp.makeRenderPipelineState(descriptor: sd)
            bloomPrefilter = try postPSO(fragment: "fs_bloom_prefilter", format: .rgba16Float)
            bloomDown = try postPSO(fragment: "fs_bloom_down", format: .rgba16Float)
            composite = try postPSO(fragment: "fs_composite", format: .bgra8Unorm_srgb)
            ssaoPipeline = try postPSO(fragment: "fs_ssao", format: .r8Unorm)
            ssaoBlurPipeline = try postPSO(fragment: "fs_ssao_blur", format: .r8Unorm)

            let dd = MTLDepthStencilDescriptor()
            dd.depthCompareFunction = .less; dd.isDepthWriteEnabled = true
            guard let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
            depthState = ds

            let td = MTL4ArgumentTableDescriptor()
            td.maxBufferBindCount = 8; td.maxTextureBindCount = 8
            table = try device.makeArgumentTable(descriptor: td)

            var rs: [MTLBuffer] = []
            for _ in 0..<Self.framesInFlight {
                guard let b = device.makeBuffer(length: Self.ringBytes, options: .storageModeShared) else { return nil }
                rs.append(b)
            }
            rings = rs
            var maps: [MTLTexture] = []
            for _ in 0..<Self.framesInFlight {
                let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: shadowSize, height: shadowSize, mipmapped: false)
                t.usage = [.renderTarget, .shaderRead]; t.storageMode = .private
                guard let m = device.makeTexture(descriptor: t) else { return nil }
                maps.append(m)
            }
            shadowMaps = maps
            var far: [MTLTexture] = []
            for _ in 0..<Self.framesInFlight {
                let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
                t.usage = [.renderTarget, .shaderRead]; t.storageMode = .private
                guard let m = device.makeTexture(descriptor: t) else { return nil }
                far.append(m)
            }
            shadowMapsFar = far
            residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
            for m in maps + far { residency.addAllocation(m) }
            for b in rings { residency.addAllocation(b) }
            residency.commit()
            queue.addResidencySet(residency)
            self.device = device
        } catch {
            NSLog("Metal 4 backend unavailable: \(error)")
            return nil
        }
    }

    /// Makes additional resources (meshes, offscreen targets) visible to the GPU.
    func makeResident(_ allocations: [MTLAllocation]) {
        for a in allocations { residency.addAllocation(a) }
        residency.commit()
    }
    func addResidencySet(_ set: MTLResidencySet) { queue.addResidencySet(set) }

    // MARK: Render targets + MetalFX scaler

    @discardableResult
    private func ensureTargets(display: CGSize, render: CGSize) -> Bool {
        let key = [Int(display.width), Int(display.height), Int(render.width), Int(render.height)]
        if let t = targets, t.key == key { return false }
        if let old = targets { for tex in old.all { residency.removeAllocation(tex) } }
        func make(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: max(w, 4), height: max(h, 4), mipmapped: false)
            d.usage = usage; d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let (dw, dh, rw, rh) = (key[0], key[1], key[2], key[3])
        var bloom: [MTLTexture] = []
        for level in 1...4 { bloom.append(make(.rgba16Float, dw >> level, dh >> level, [.renderTarget, .shaderRead])) }
        let ao = [make(.r8Unorm, rw / 2, rh / 2, [.renderTarget, .shaderRead]), make(.r8Unorm, rw / 2, rh / 2, [.renderTarget, .shaderRead])]
        let t = SceneTargets(key: key,
                             color: make(.rgba16Float, rw, rh, [.renderTarget, .shaderRead]),
                             motion: make(.rg16Float, rw, rh, [.renderTarget, .shaderRead]),
                             depth: make(.depth32Float, rw, rh, [.renderTarget, .shaderRead]),
                             upscaled: make(.rgba16Float, dw, dh, [.renderTarget, .shaderRead, .shaderWrite]),
                             bloom: bloom, ao: ao)
        targets = t
        for tex in t.all { residency.addAllocation(tex) }
        residency.commit()

        let d = MTLFXTemporalScalerDescriptor()
        d.inputWidth = rw; d.inputHeight = rh; d.outputWidth = dw; d.outputHeight = dh
        d.colorTextureFormat = .rgba16Float; d.depthTextureFormat = .depth32Float
        d.motionTextureFormat = .rg16Float; d.outputTextureFormat = .rgba16Float
        if let s = d.makeTemporalScaler(device: device, compiler: compiler) {
            s.motionVectorScaleX = Float(rw); s.motionVectorScaleY = Float(rh)     // motion vectors are in uv units
            scaler = s
        } else {
            NSLog("MetalFX temporal scaler unavailable for \(rw)x\(rh) → \(dw)x\(dh); rendering at native resolution")
            scaler = nil
            if (rw, rh) != (dw, dh) { Self.upscalerUnavailable = true }
        }
        return true
    }

    // MARK: Frame

    /// Encodes and submits one frame. Returns the frame's event value; wait on it for completion.
    @discardableResult
    func render(frame fd: FrameData, displaySize: CGSize, renderScale: Float, board: MTLTexture, ads: MTLTexture, mesh: (DrawItem) -> Mesh?,
                crowd: (mesh: Mesh, buffer: MTLBuffer, count: Int)?, finalPass: MTL4RenderPassDescriptor,
                drawable: CAMetalDrawable?, gpuTime: ((Double) -> Void)?) -> UInt64 {
        let renderSize = Self.renderSize(display: displaySize, scale: renderScale)
        let recreated = ensureTargets(display: displaySize, render: renderSize)
        guard let tg = targets else { return frame }

        frame += 1
        let slot = Int(frame % UInt64(Self.framesInFlight))
        if frame > UInt64(Self.framesInFlight) { _ = event.wait(untilSignaledValue: frame - UInt64(Self.framesInFlight), timeoutMS: 2000) }
        allocators[slot].reset()
        cmd.beginCommandBuffer(allocator: allocators[slot])

        let ring = rings[slot], shadowMap = shadowMaps[slot], shadowFar = shadowMapsFar[slot]
        var offset = 0
        func put<T>(_ v: T) -> MTLGPUAddress {
            precondition(offset + 256 <= Self.ringBytes, "uniform ring overflow")
            var value = v
            memcpy(ring.contents() + offset, &value, MemoryLayout<T>.size)
            defer { offset += (MemoryLayout<T>.stride + 255) & ~255 }
            return ring.gpuAddress + MTLGPUAddress(offset)
        }
        let fu = fd.uniforms
        var sfu = fu; sfu.viewProj = fu.lightViewProj
        let frameAddr = put(fu), shadowFrameAddr = put(sfu)
        func putArray(_ a: [float4x4]) -> MTLGPUAddress {
            let bytes = a.count * MemoryLayout<float4x4>.stride
            precondition(offset + bytes <= Self.ringBytes, "uniform ring overflow (palette)")
            a.withUnsafeBytes { memcpy(ring.contents() + offset, $0.baseAddress!, bytes) }
            defer { offset += (bytes + 255) & ~255 }
            return ring.gpuAddress + MTLGPUAddress(offset)
        }
        // Per-character GPU data written once per frame and shared by the shadow and main passes.
        let charAddrs: [(pal: MTLGPUAddress, prev: MTLGPUAddress, morph: MTLGPUAddress)] = fd.characters.map { (putArray($0.palette), putArray($0.prevPalette), put($0.morph)) }
        func drawCharacters(_ enc: MTL4RenderCommandEncoder, shadow: Bool) {
            for (c, a) in zip(fd.characters, charAddrs) {
                table.setAddress(a.pal, index: 4); table.setAddress(a.prev, index: 5); table.setAddress(a.morph, index: 6)
                for pd in c.parts where !shadow || pd.castsShadow {
                    let mc = pd.part.morphBuffer != nil ? pd.part.vertexCount : 0
                    table.setAddress(put(DrawUniforms(model: c.model, prevModel: c.prevModel, color: pd.color, accent: pd.accent,
                                                      params: float4(Float(pd.material), pd.spec, pd.rough, Float(mc)))), index: 2)
                    table.setAddress(pd.part.vertexBuffer.gpuAddress, index: 0)
                    table.setAddress((pd.part.morphBuffer ?? pd.part.vertexBuffer).gpuAddress, index: 7)
                    enc.setCullMode(shadow || !pd.cullBack ? .none : .back)
                    enc.drawIndexedPrimitives(primitiveType: .triangle, indexCount: pd.part.indexCount, indexType: .uint32,
                                              indexBuffer: pd.part.indexBuffer.gpuAddress, indexBufferLength: pd.part.indexBuffer.length)
                }
            }
        }

        func draw(_ item: DrawItem, _ enc: MTL4RenderCommandEncoder) {
            guard let m = mesh(item) else { return }
            table.setAddress(put(DrawUniforms(model: item.model, prevModel: item.prevModel ?? item.model, color: item.color, accent: item.accent,
                                              params: float4(Float(item.material), item.spec, item.rough, Float(item.part ?? 0)))), index: 2)
            table.setAddress(m.vertexBuffer.gpuAddress, index: 0)
            enc.drawIndexedPrimitives(primitiveType: .triangle, indexCount: m.indexCount, indexType: .uint16,
                                      indexBuffer: m.indexBuffer.gpuAddress, indexBufferLength: m.indexBuffer.length)
        }

        // 1. Sun shadow map (this slot's own texture; the CPU already waited for the slot's previous frame).
        let sp = MTL4RenderPassDescriptor()
        sp.depthAttachment.texture = shadowMap; sp.depthAttachment.loadAction = .clear
        sp.depthAttachment.storeAction = .store; sp.depthAttachment.clearDepth = 1
        if let se = cmd.makeRenderCommandEncoder(descriptor: sp) {
            se.setRenderPipelineState(shadowPipeline); se.setDepthStencilState(depthState)
            se.setCullMode(.none); se.setFrontFacing(.counterClockwise)
            se.setDepthBias(0.0, slopeScale: 1.5, clamp: 0.01)
            se.setArgumentTable(table, stages: .vertex)
            table.setAddress(shadowFrameAddr, index: 1)
            for item in fd.items where item.castsShadow { draw(item, se) }
            se.setRenderPipelineState(skinnedShadowPipeline); drawCharacters(se, shadow: true)
            se.endEncoding()
        }
        // 1b. Far cascade: the whole bowl and roof, so the roof shades the crowd.
        var sfu2 = fu; sfu2.viewProj = fu.lightViewProj2
        let shadowFrameAddr2 = put(sfu2)
        let sp2 = MTL4RenderPassDescriptor()
        sp2.depthAttachment.texture = shadowFar; sp2.depthAttachment.loadAction = .clear
        sp2.depthAttachment.storeAction = .store; sp2.depthAttachment.clearDepth = 1
        if let se = cmd.makeRenderCommandEncoder(descriptor: sp2) {
            se.setRenderPipelineState(shadowPipeline); se.setDepthStencilState(depthState)
            se.setCullMode(.none); se.setFrontFacing(.counterClockwise)
            se.setDepthBias(0.0, slopeScale: 2.0, clamp: 0.02)
            se.setArgumentTable(table, stages: .vertex)
            table.setAddress(shadowFrameAddr2, index: 1)
            for item in fd.items where item.castsShadow { draw(item, se) }
            se.endEncoding()                                      // athletes stay out of the far cascade: the near cascade covers the court
        }

        // 2. Scene pass at render resolution: HDR colour + motion vectors + depth.
        let scenePass = MTL4RenderPassDescriptor()
        scenePass.colorAttachments[0].texture = tg.color
        scenePass.colorAttachments[0].loadAction = .clear; scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0.4, green: 0.55, blue: 0.8, alpha: 1)
        scenePass.colorAttachments[1].texture = tg.motion
        scenePass.colorAttachments[1].loadAction = .clear; scenePass.colorAttachments[1].storeAction = .store
        scenePass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        scenePass.depthAttachment.texture = tg.depth
        scenePass.depthAttachment.loadAction = .clear; scenePass.depthAttachment.storeAction = .store
        scenePass.depthAttachment.clearDepth = 1
        if let me = cmd.makeRenderCommandEncoder(descriptor: scenePass) {
            me.barrier(afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: .device)   // shadow map written above
            me.setRenderPipelineState(scenePipeline); me.setDepthStencilState(depthState)
            me.setFrontFacing(.counterClockwise)
            me.setArgumentTable(table, stages: [.vertex, .fragment])
            table.setAddress(frameAddr, index: 1)
            table.setTexture(shadowMap.gpuResourceID, index: 0)
            table.setTexture(board.gpuResourceID, index: 1)
            table.setTexture(shadowFar.gpuResourceID, index: 2)
            table.setTexture(ads.gpuResourceID, index: 3)
            for item in fd.items {
                me.setCullMode(item.material == 4 ? .none : .back)
                draw(item, me)
            }
            if let c = crowd {                                         // GPU-instanced audience: one draw call
                me.setRenderPipelineState(crowdPipeline)
                me.setCullMode(.back)
                table.setAddress(c.mesh.vertexBuffer.gpuAddress, index: 0)
                table.setAddress(c.buffer.gpuAddress, index: 3)
                me.drawIndexedPrimitives(primitiveType: .triangle, indexCount: c.mesh.indexCount, indexType: .uint16,
                                         indexBuffer: c.mesh.indexBuffer.gpuAddress, indexBufferLength: c.mesh.indexBuffer.length,
                                         instanceCount: c.count)
            }
            me.setRenderPipelineState(skinnedPipeline)                  // skinned athletes (skin / eyes / hair / clothing)
            drawCharacters(me, shadow: false)
            me.barrier(afterStages: .fragment, beforeQueueStages: .all, visibilityOptions: .device)  // MetalFX reads the targets
            me.endEncoding()
        }

        // 3. MetalFX temporal anti-aliasing + upscaling.
        var postSource = tg.color
        if let sc = scaler {
            sc.colorTexture = tg.color; sc.depthTexture = tg.depth; sc.motionTexture = tg.motion; sc.outputTexture = tg.upscaled
            sc.jitterOffsetX = fd.pixelJitter.x; sc.jitterOffsetY = fd.pixelJitter.y
            sc.isDepthReversed = false
            sc.reset = fd.resetHistory || recreated
            sc.encode(commandBuffer: cmd)
            postSource = tg.upscaled
        }

        // 4–5. Bloom chain and composite. Each pass is a fullscreen triangle sampling previous results through the argument table.
        func fullscreen(_ pass: MTL4RenderPassDescriptor, _ pso: MTLRenderPipelineState, textures: [MTLTexture], params: PostParams,
                        after: MTLStages) {
            guard let e = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            e.barrier(afterQueueStages: after, beforeStages: .fragment, visibilityOptions: .device)
            e.setRenderPipelineState(pso)
            e.setArgumentTable(table, stages: .fragment)
            for (i, t) in textures.enumerated() { table.setTexture(t.gpuResourceID, index: i) }
            table.setAddress(put(params), index: 0)
            e.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        func target(_ t: MTLTexture) -> MTL4RenderPassDescriptor {
            let p = MTL4RenderPassDescriptor()
            p.colorAttachments[0].texture = t; p.colorAttachments[0].loadAction = .dontCare; p.colorAttachments[0].storeAction = .store
            return p
        }
        func params(_ src: MTLTexture) -> PostParams {
            PostParams(a: SIMD4(1 / Float(src.width), 1 / Float(src.height), 1.7, 0.8),
                       b: SIMD4(0.5, 1.0, 0.34, Float(frame % 997)),
                       c: SIMD4(fd.post.focusDist, 0.7, 0.5, 6.0),
                       d: SIMD4(Float(renderSize.width), Float(renderSize.height), fd.post.depthA, fd.post.depthB),
                       e: SIMD4(fd.post.p00, fd.post.p11, 0.85, 0.35))
        }
        // SSAO from the scene depth (half resolution) + blur, ready before the composite.
        fullscreen(target(tg.ao[0]), ssaoPipeline, textures: [tg.depth], params: params(tg.ao[0]), after: .fragment)
        fullscreen(target(tg.ao[1]), ssaoBlurPipeline, textures: [tg.ao[0], tg.depth], params: params(tg.ao[0]), after: .fragment)
        fullscreen(target(tg.bloom[0]), bloomPrefilter, textures: [postSource], params: params(postSource), after: [.dispatch, .fragment, .blit])
        for i in 1..<tg.bloom.count {
            fullscreen(target(tg.bloom[i]), bloomDown, textures: [tg.bloom[i - 1]], params: params(tg.bloom[i - 1]), after: .fragment)
        }
        fullscreen(finalPass, composite, textures: [postSource] + tg.bloom + [tg.depth, tg.motion, tg.ao[1]], params: params(postSource), after: .fragment)
        cmd.endCommandBuffer()

        if let d = drawable { queue.waitForDrawable(d) }
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { fb in gpuTime?((fb.gpuEndTime - fb.gpuStartTime) * 1000) }
        queue.commit([cmd], options: options)
        if let d = drawable { queue.signalDrawable(d); d.present() }
        queue.signalEvent(event, value: frame)
        return frame
    }

    /// Blocks until every submitted frame has finished.
    func drain() { waitUntilCompleted(frame) }

    func waitUntilCompleted(_ value: UInt64) { _ = event.wait(untilSignaledValue: value, timeoutMS: 10_000) }
}
#else
/// Simulator stub: Metal 4 is unavailable, so the Renderer always uses the classic path.
final class Metal4Backend {
    static func renderSize(display: CGSize, scale: Float) -> CGSize { display }
    init?(device: MTLDevice, library: MTLLibrary, vertexDescriptor: MTLVertexDescriptor, shadowSize: Int) { return nil }
    func makeResident(_ allocations: [MTLAllocation]) {}
    func addResidencySet(_ set: MTLResidencySet) {}
    func drain() {}
    func waitUntilCompleted(_ value: UInt64) {}
}
#endif
