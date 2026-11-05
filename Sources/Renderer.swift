import AppKit
import Metal
import MetalKit
import QuartzCore

final class SnowRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let flakePipeline: MTLRenderPipelineState
    private let driftPipeline: MTLRenderPipelineState
    private let uniformBuffer: MTLBuffer

    private let engine: SnowEngine
    private let layer: SnowLayer

    // Triple-buffered vertex data: the GPU may still be reading the buffer from
    // an earlier frame while the CPU writes the next one.
    private var flakeBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var flakeCaps = [0, 0, 0]
    private var driftBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var driftCaps = [0, 0, 0]
    private var bufferIndex = 0

    init?(device: MTLDevice, engine: SnowEngine, layer: SnowLayer, sampleCount: Int = 1) {
        guard let queue = device.makeCommandQueue() else { return nil }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            NSLog("Snow: shader compile failed: \(error)")
            return nil
        }

        guard let vFlake = library.makeFunction(name: "flake_vertex"),
              let fFlake = library.makeFunction(name: "flake_fragment"),
              let vDrift = library.makeFunction(name: "drift_vertex"),
              let fDrift = library.makeFunction(name: "drift_fragment") else { return nil }

        func makePipeline(_ v: MTLFunction, _ f: MTLFunction) -> MTLRenderPipelineState? {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = v
            desc.fragmentFunction = f
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
            return try? device.makeRenderPipelineState(descriptor: desc)
        }

        guard let fp = makePipeline(vFlake, fFlake),
              let dp = makePipeline(vDrift, fDrift) else { return nil }

        guard let ub = device.makeBuffer(length: MemoryLayout<Uniforms>.stride,
                                         options: .storageModeShared) else { return nil }

        self.device = device
        self.queue = queue
        self.flakePipeline = fp
        self.driftPipeline = dp
        self.uniformBuffer = ub
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

        // Accumulated drifts
        let driftVerts = (layer == .back) ? engine.backDrift : engine.frontDrift
        if !driftVerts.isEmpty {
            let buf = uploadDrift(driftVerts, slot: slot)
            if buf != nil {
                encoder.setRenderPipelineState(driftPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: driftVerts.count)
            }
        }

        // Falling flakes
        let instances = (layer == .back) ? engine.backFlakes : engine.frontFlakes
        if !instances.isEmpty {
            let buf = uploadFlakes(instances, slot: slot)
            if buf != nil {
                encoder.setRenderPipelineState(flakePipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: 6, instanceCount: instances.count)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func uploadDrift(_ array: [DriftVertex], slot: Int) -> MTLBuffer? {
        let bytes = array.count * MemoryLayout<DriftVertex>.stride
        if driftBuffers[slot] == nil || driftCaps[slot] < bytes {
            let cap = max(8192, bytes * 2)
            driftBuffers[slot] = device.makeBuffer(length: cap, options: .storageModeShared)
            driftCaps[slot] = cap
        }
        guard let buf = driftBuffers[slot] else { return nil }
        array.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buf.contents(), base, bytes) }
        }
        return buf
    }

    private func uploadFlakes(_ array: [FlakeInstance], slot: Int) -> MTLBuffer? {
        let bytes = array.count * MemoryLayout<FlakeInstance>.stride
        if flakeBuffers[slot] == nil || flakeCaps[slot] < bytes {
            let cap = max(8192, bytes * 2)
            flakeBuffers[slot] = device.makeBuffer(length: cap, options: .storageModeShared)
            flakeCaps[slot] = cap
        }
        guard let buf = flakeBuffers[slot] else { return nil }
        array.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buf.contents(), base, bytes) }
        }
        return buf
    }
}
