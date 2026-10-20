import BeebHost
import Metal
import MetalKit

/// Draws the emulator's frames with Metal.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    /// Display aspect ratio of the TV picture (b2's correction: the 16MHz
    /// pixels are slightly narrower than square at 576 lines).
    static let aspect: CGFloat = CGFloat(EmulatorHost.Frame.width) * 24 / 25 / CGFloat(EmulatorHost.Frame.height)

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let texture: MTLTexture
    let host: EmulatorHost
    var shownFrame = -1
    var linearFiltering = true

    init?(view: MTKView, host: EmulatorHost) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.host = host

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("MacBeeb: couldn't build Metal pipeline: \(error)")
            return nil
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: EmulatorHost.Frame.width,
            height: EmulatorHost.Frame.height,
            mipmapped: false)
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        self.texture = texture
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if let frame = host.frame, frame.number != shownFrame {
            shownFrame = frame.number
            frame.pixels.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, EmulatorHost.Frame.width, EmulatorHost.Frame.height),
                                mipmapLevel: 0,
                                withBytes: bytes.baseAddress!,
                                bytesPerRow: EmulatorHost.Frame.width * 4)
            }
        }

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // Letterbox to the TV's aspect ratio.
        let size = view.drawableSize
        var width = size.width, height = size.width / Self.aspect
        if height > size.height {
            height = size.height
            width = height * Self.aspect
        }
        encoder.setViewport(MTLViewport(originX: (size.width - width) / 2, originY: (size.height - height) / 2,
                                        width: width, height: height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        var linear: UInt32 = linearFiltering ? 1 : 0
        encoder.setFragmentBytes(&linear, length: 4, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut vertexMain(uint id [[vertex_id]]) {
        float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        VertexOut out;
        out.position = float4(corners[id], 0, 1);
        out.uv = float2((corners[id].x + 1) * 0.5, (1 - corners[id].y) * 0.5);
        return out;
    }

    fragment float4 fragmentMain(VertexOut in [[stage_in]],
                                 texture2d<float> frame [[texture(0)]],
                                 constant uint &linear [[buffer(0)]]) {
        constexpr sampler nearestSampler(filter::nearest);
        constexpr sampler linearSampler(filter::linear);
        float3 rgb = linear ? frame.sample(linearSampler, in.uv).rgb : frame.sample(nearestSampler, in.uv).rgb;
        return float4(rgb, 1);
    }
    """
}
