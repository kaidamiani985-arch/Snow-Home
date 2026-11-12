import AppKit
import Metal
import MetalKit
import QuartzCore

final class AutumnRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let uniformBuffer: MTLBuffer
    private let atlas: MTLTexture
    private let sampler: MTLSamplerState

    private let engine: AutumnEngine
    private let layer: SnowLayer

    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var capacities = [0, 0, 0]
    private var bufferIndex = 0

    init?(device: MTLDevice, engine: AutumnEngine, layer: SnowLayer, sampleCount: Int = 1) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            NSLog("Seasons: leaf shader compile failed: \(error)")
            return nil
        }
        guard let vFn = library.makeFunction(name: "leaf_vertex"),
              let fFn = library.makeFunction(name: "leaf_fragment") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vFn
        desc.fragmentFunction = fFn
        desc.rasterSampleCount = sampleCount
        let att = desc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .sourceAlpha
        att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }

        guard let url = Bundle.main.url(forResource: "Leaves", withExtension: "png") else {
            NSLog("Seasons: Leaves.png missing")
            return nil
        }
        let loader = MTKTextureLoader(device: device)
        guard let atlas = try? loader.newTexture(URL: url, options: [
            .SRGB: true,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue
        ]) else { return nil }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
        guard let ub = device.makeBuffer(length: MemoryLayout<Uniforms>.stride,
                                         options: .storageModeShared) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.uniformBuffer = ub
        self.atlas = atlas
        self.sampler = sampler
        self.engine = engine
        self.layer = layer
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        engine.stepIfNeeded(CACurrentMediaTime())

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        bufferIndex = (bufferIndex + 1) % 3
        let slot = bufferIndex
        var uniforms = Uniforms(
            size: SIMD2<Float>(Float(size.width), Float(size.height)),
            time: 0,
            pad: 0
        )
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)

        let instances = (layer == .back) ? engine.backLeaves : engine.frontLeaves
        if !instances.isEmpty, let buf = upload(instances, slot: slot) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 1)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: 6, instanceCount: instances.count)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func upload(_ array: [LeafInstance], slot: Int) -> MTLBuffer? {
        let bytes = array.count * MemoryLayout<LeafInstance>.stride
        if buffers[slot] == nil || capacities[slot] < bytes {
            let cap = max(8192, bytes * 2)
            buffers[slot] = device.makeBuffer(length: cap, options: .storageModeShared)
            capacities[slot] = cap
        }
        guard let buf = buffers[slot] else { return nil }
        array.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buf.contents(), base, bytes) }
        }
        return buf
    }
}
