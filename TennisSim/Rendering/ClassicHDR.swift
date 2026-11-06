import Metal
import MetalKit

/// HDR frame graph for GPUs / SDKs without Metal 4 (iOS Simulator, older devices). Same look as the Metal 4 backend minus MetalFX:
///   1. two sun shadow cascades (court + stadium bowl)
///   2. scene pass: 4× MSAA HDR colour (rgba16f) + motion vectors + depth, resolved; instanced crowd + skinned athletes
///   3. SSAO (half res) + depth-aware blur
///   4. bloom: soft-threshold prefilter + three tent downsamples
///   5. composite: DOF + motion blur, sharpen, AO, bloom, grade, ACES, vignette → drawable
final class ClassicHDR {
    struct PostParams { var a: SIMD4<Float>; var b: SIMD4<Float>; var c: SIMD4<Float>; var d: SIMD4<Float>; var e: SIMD4<Float> }
    private struct Targets {
        var size: MTLSize
        var colorMS: MTLTexture, color: MTLTexture, motionMS: MTLTexture, motion: MTLTexture, depthMS: MTLTexture, depth: MTLTexture
        var bloom: [MTLTexture], ao: [MTLTexture]
    }

    let device: MTLDevice
    private let scene: MTLRenderPipelineState, crowd: MTLRenderPipelineState
    private let skinned: MTLRenderPipelineState, skinnedShadow: MTLRenderPipelineState
    private let prefilter: MTLRenderPipelineState, down: MTLRenderPipelineState, composite: MTLRenderPipelineState
    private let ssao: MTLRenderPipelineState, ssaoBlur: MTLRenderPipelineState
    let shadowFar: MTLTexture
    private var targets: Targets?
    private var frameCounter: UInt32 = 0
    static let msaa = 4

    init?(device: MTLDevice, library lib: MTLLibrary, vertexDescriptor vd: MTLVertexDescriptor) {
        self.device = device
        func scenePSO(_ vs: String, descriptor: MTLVertexDescriptor?) -> MTLRenderPipelineState? {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: vs); pd.fragmentFunction = lib.makeFunction(name: "fs_hdr")
            pd.vertexDescriptor = descriptor; pd.rasterSampleCount = Self.msaa
            pd.colorAttachments[0].pixelFormat = .rgba16Float
            pd.colorAttachments[1].pixelFormat = .rg16Float
            pd.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: pd)
        }
        func postPSO(_ fs: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "vs_fullscreen"); pd.fragmentFunction = lib.makeFunction(name: fs)
            pd.colorAttachments[0].pixelFormat = fmt
            return try? device.makeRenderPipelineState(descriptor: pd)
        }
        let ssd = MTLRenderPipelineDescriptor()
        ssd.vertexFunction = lib.makeFunction(name: "vs_skinned"); ssd.depthAttachmentPixelFormat = .depth32Float
        guard let s = scenePSO("vs_main", descriptor: vd), let c = scenePSO("vs_crowd", descriptor: vd),
              let sk = scenePSO("vs_skinned", descriptor: nil), let sks = try? device.makeRenderPipelineState(descriptor: ssd),
              let pf = postPSO("fs_bloom_prefilter", .rgba16Float), let dn = postPSO("fs_bloom_down", .rgba16Float),
              let co = postPSO("fs_composite", .bgra8Unorm_srgb), let ao = postPSO("fs_ssao", .r8Unorm),
              let ab = postPSO("fs_ssao_blur", .r8Unorm) else { return nil }
        scene = s; crowd = c; skinned = sk; skinnedShadow = sks; prefilter = pf; down = dn; composite = co; ssao = ao; ssaoBlur = ab
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        guard let far = device.makeTexture(descriptor: td) else { return nil }
        shadowFar = far
    }

    private func ensureTargets(_ w: Int, _ h: Int) -> Targets {
        if let t = targets, t.size.width == w, t.size.height == h { return t }
        func make(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, ms: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: max(w, 4), height: max(h, 4), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            if ms { d.textureType = .type2DMultisample; d.sampleCount = Self.msaa }
            return device.makeTexture(descriptor: d)!
        }
        let t = Targets(size: MTLSize(width: w, height: h, depth: 1),
                        colorMS: make(.rgba16Float, w, h, ms: true), color: make(.rgba16Float, w, h),
                        motionMS: make(.rg16Float, w, h, ms: true), motion: make(.rg16Float, w, h),
                        depthMS: make(.depth32Float, w, h, ms: true), depth: make(.depth32Float, w, h),
                        bloom: (1...4).map { make(.rgba16Float, w >> $0, h >> $0) },
                        ao: [make(.r8Unorm, w / 2, h / 2), make(.r8Unorm, w / 2, h / 2)])
        targets = t
        return t
    }

    func encode(cb: MTLCommandBuffer, frame fd: FrameData, finalPass: MTLRenderPassDescriptor, size: CGSize, r: Renderer) {
        let (w, h) = (Int(size.width), Int(size.height))
        guard w > 8, h > 8 else { return }
        let tg = ensureTargets(w, h)
        frameCounter &+= 1
        var fu = fd.uniforms

        func drawCharacters(_ e: MTLRenderCommandEncoder, shadow: Bool) {
            for c in fd.characters {
                var pal = c.palette, prev = c.prevPalette, morph = c.morph
                let bytes = pal.count * MemoryLayout<float4x4>.stride
                e.setVertexBytes(&pal, length: bytes, index: 4)
                e.setVertexBytes(&prev, length: bytes, index: 5)
                e.setVertexBytes(&morph, length: MemoryLayout<float4>.stride, index: 6)
                for pd in c.parts where !shadow || pd.castsShadow {
                    let mc = pd.part.morphBuffer != nil ? pd.part.vertexCount : 0
                    var du = DrawUniforms(model: c.model, prevModel: c.prevModel, color: pd.color, accent: pd.accent,
                                          params: float4(Float(pd.material), pd.spec, pd.rough, Float(mc)))
                    e.setVertexBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    e.setVertexBuffer(pd.part.vertexBuffer, offset: 0, index: 0)
                    e.setVertexBuffer(pd.part.morphBuffer ?? pd.part.vertexBuffer, offset: 0, index: 7)
                    e.setCullMode(shadow || !pd.cullBack ? .none : .back)
                    e.drawIndexedPrimitives(type: .triangle, indexCount: pd.part.indexCount, indexType: .uint32,
                                            indexBuffer: pd.part.indexBuffer, indexBufferOffset: 0)
                }
            }
        }

        // 1. Shadow cascades.
        func shadowPass(_ map: MTLTexture, viewProj: float4x4, slope: Float, clamp: Float, characters: Bool) {
            let sp = MTLRenderPassDescriptor()
            sp.depthAttachment.texture = map; sp.depthAttachment.loadAction = .clear
            sp.depthAttachment.storeAction = .store; sp.depthAttachment.clearDepth = 1
            guard let se = cb.makeRenderCommandEncoder(descriptor: sp) else { return }
            var sfu = fu; sfu.viewProj = viewProj
            se.setRenderPipelineState(r.shadowPipeline); se.setDepthStencilState(r.depthState)
            se.setCullMode(.none); se.setDepthBias(0.0, slopeScale: slope, clamp: clamp)
            se.setFrontFacing(.counterClockwise)
            se.setVertexBytes(&sfu, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            for item in fd.items where item.castsShadow { r.draw(item, on: se) }
            if characters {
                se.setRenderPipelineState(skinnedShadow)
                se.setVertexBytes(&sfu, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                drawCharacters(se, shadow: true)
            }
            se.endEncoding()
        }
        shadowPass(r.shadowMap, viewProj: fu.lightViewProj, slope: 1.5, clamp: 0.01, characters: true)
        shadowPass(shadowFar, viewProj: fu.lightViewProj2, slope: 2.0, clamp: 0.02, characters: false)

        // 2. Scene → MSAA HDR targets, resolved.
        let sp = MTLRenderPassDescriptor()
        sp.colorAttachments[0].texture = tg.colorMS; sp.colorAttachments[0].resolveTexture = tg.color
        sp.colorAttachments[0].loadAction = .clear; sp.colorAttachments[0].storeAction = .multisampleResolve
        sp.colorAttachments[0].clearColor = MTLClearColor(red: 0.4, green: 0.55, blue: 0.8, alpha: 1)
        sp.colorAttachments[1].texture = tg.motionMS; sp.colorAttachments[1].resolveTexture = tg.motion
        sp.colorAttachments[1].loadAction = .clear; sp.colorAttachments[1].storeAction = .multisampleResolve
        sp.depthAttachment.texture = tg.depthMS; sp.depthAttachment.resolveTexture = tg.depth
        sp.depthAttachment.depthResolveFilter = .sample0
        sp.depthAttachment.loadAction = .clear; sp.depthAttachment.storeAction = .multisampleResolve; sp.depthAttachment.clearDepth = 1
        if let e = cb.makeRenderCommandEncoder(descriptor: sp) {
            e.setRenderPipelineState(scene); e.setDepthStencilState(r.depthState)
            e.setFrontFacing(.counterClockwise)
            e.setVertexBytes(&fu, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            e.setFragmentBytes(&fu, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            e.setFragmentTexture(r.shadowMap, index: 0)
            e.setFragmentTexture(r.scoreboard.texture, index: 1)
            e.setFragmentTexture(shadowFar, index: 2)
            e.setFragmentTexture(r.adTexture.texture, index: 3)
            for item in fd.items {
                e.setCullMode(item.material == 4 ? .none : .back)
                r.draw(item, on: e)
            }
            if let c = r.crowdDraw {
                e.setRenderPipelineState(crowd); e.setCullMode(.back)
                e.setVertexBuffer(c.mesh.vertexBuffer, offset: 0, index: 0)
                e.setVertexBuffer(c.buffer, offset: 0, index: 3)
                e.drawIndexedPrimitives(type: .triangle, indexCount: c.mesh.indexCount, indexType: .uint16,
                                        indexBuffer: c.mesh.indexBuffer, indexBufferOffset: 0, instanceCount: c.count)
            }
            if !fd.characters.isEmpty {
                e.setRenderPipelineState(skinned)
                e.setVertexBytes(&fu, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                drawCharacters(e, shadow: false)
            }
            e.endEncoding()
        }

        // 3–5. Post chain.
        func params(_ src: MTLTexture) -> PostParams {
            PostParams(a: SIMD4(1 / Float(src.width), 1 / Float(src.height), 1.7, 0.8),
                       b: SIMD4(0.5, 1.0, 0.34, Float(frameCounter % 997)),
                       c: SIMD4(fd.post.focusDist, 0.7, 0.5, 6.0),
                       d: SIMD4(Float(w), Float(h), fd.post.depthA, fd.post.depthB),
                       e: SIMD4(fd.post.p00, fd.post.p11, 0.85, 0.35))
        }
        func fullscreen(_ pass: MTLRenderPassDescriptor, _ pso: MTLRenderPipelineState, _ textures: [MTLTexture], _ p: PostParams) {
            guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            e.setRenderPipelineState(pso)
            for (i, t) in textures.enumerated() { e.setFragmentTexture(t, index: i) }
            var pp = p
            e.setFragmentBytes(&pp, length: MemoryLayout<PostParams>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        func target(_ t: MTLTexture) -> MTLRenderPassDescriptor {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = t; p.colorAttachments[0].loadAction = .dontCare; p.colorAttachments[0].storeAction = .store
            return p
        }
        fullscreen(target(tg.ao[0]), ssao, [tg.depth], params(tg.ao[0]))
        fullscreen(target(tg.ao[1]), ssaoBlur, [tg.ao[0], tg.depth], params(tg.ao[0]))
        fullscreen(target(tg.bloom[0]), prefilter, [tg.color], params(tg.color))
        for i in 1..<tg.bloom.count { fullscreen(target(tg.bloom[i]), down, [tg.bloom[i - 1]], params(tg.bloom[i - 1])) }
        fullscreen(finalPass, composite, [tg.color] + tg.bloom + [tg.depth, tg.motion, tg.ao[1]], params(tg.color))
    }
}
