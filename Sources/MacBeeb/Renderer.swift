import BeebHost
import Metal
import MetalKit

/// How the picture is drawn.
enum DisplayStyle: String, CaseIterable, Identifiable {
    /// Nearest-neighbour pixels.
    case sharp
    /// Bilinear filtering.
    case smooth
    /// A CRT: visible scanlines whose width follows brightness, and an
    /// aperture grille when the window is big enough to show it.
    case crt

    var id: Self { self }

    var name: String {
        switch self {
        case .sharp: "Sharp Pixels"
        case .smooth: "Smooth"
        case .crt: "CRT"
        }
    }

    static let defaultsKey = "MacBeebDisplayStyle"

    static var saved: DisplayStyle {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(DisplayStyle.init(rawValue:)) ?? .sharp
    }
}

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
    var style = DisplayStyle.saved

    /// Matches `Uniforms` in the shader.
    struct Uniforms {
        var style: UInt32
        var viewportHeight: Float
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, host: EmulatorHost) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.host = host

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
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
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        encode(into: commands, descriptor: descriptor, size: view.drawableSize)
        commands.present(drawable)
        commands.commit()
    }

    private func uploadLatestFrame() {
        guard let frame = host.frame, frame.number != shownFrame else { return }
        shownFrame = frame.number
        frame.pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, EmulatorHost.Frame.width, EmulatorHost.Frame.height),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: EmulatorHost.Frame.width * 4)
        }
    }

    private func encode(into commands: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, size: CGSize) {
        uploadLatestFrame()
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // Letterbox to the TV's aspect ratio.
        var width = size.width, height = size.width / Self.aspect
        if height > size.height {
            height = size.height
            width = height * Self.aspect
        }
        encoder.setViewport(MTLViewport(originX: (size.width - width) / 2, originY: (size.height - height) / 2,
                                        width: width, height: height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        let styleIndex: UInt32 = switch style {
        case .sharp: 0
        case .smooth: 1
        case .crt: 2
        }
        var uniforms = Uniforms(style: styleIndex, viewportHeight: Float(height))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Renders the current frame offscreen, as the window would show it at
    /// `width` x `height` pixels. (For self-tests and screenshots of the
    /// display as seen.)
    func renderImage(width: Int, height: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        encode(into: commands, descriptor: pass, size: CGSize(width: width, height: height))
        commands.commit()
        commands.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        uint style;
        float viewportHeight;
    };

    vertex VertexOut vertexMain(uint id [[vertex_id]]) {
        float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        VertexOut out;
        out.position = float4(corners[id], 0, 1);
        out.uv = float2((corners[id].x + 1) * 0.5, (1 - corners[id].y) * 0.5);
        return out;
    }

    constant float beamLines = 288;

    // One beam line's colour at x, in linear light, slightly blurred
    // horizontally like a real spot.
    float3 lineColour(texture2d<float> frame, float x, float line) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = (clamp(line, 0.0, beamLines - 1) + 0.5) / beamLines;
        float dx = 0.6 / frame.get_width();
        float3 c = frame.sample(s, float2(x, y)).rgb * 0.5
                 + frame.sample(s, float2(x - dx, y)).rgb * 0.25
                 + frame.sample(s, float2(x + dx, y)).rgb * 0.25;
        return pow(c, 2.4);
    }

    // The beam's vertical profile: brighter lines bloom wider.
    float3 beam(float3 colour, float distance) {
        float3 width = mix(float3(0.24), float3(0.32), sqrt(colour));
        return colour * exp(-0.5 * distance * distance / (width * width));
    }

    fragment float4 fragmentMain(VertexOut in [[stage_in]],
                                 texture2d<float> frame [[texture(0)]],
                                 constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler nearestSampler(filter::nearest);
        constexpr sampler linearSampler(filter::linear);
        if (u.style == 0) {
            return float4(frame.sample(nearestSampler, in.uv).rgb, 1);
        }
        if (u.style == 1) {
            return float4(frame.sample(linearSampler, in.uv).rgb, 1);
        }

        // CRT. Below about 2 output pixels per line, scanlines alias:
        // fade them out.
        float pixelsPerLine = u.viewportHeight / beamLines;
        float scanlineStrength = saturate((pixelsPerLine - 1.5) / 1.5);

        float y = in.uv.y * beamLines;
        float line = floor(y);
        float offset = y - line - 0.5;
        float neighbour = offset < 0 ? line - 1 : line + 1;
        float3 here = lineColour(frame, in.uv.x, line);
        float3 next = lineColour(frame, in.uv.x, neighbour);
        float3 scanned = beam(here, offset) + beam(next, 1 - abs(offset));
        // Keep average brightness about the same as the flat picture.
        scanned *= 1.15;
        float3 flat = mix(here, next, abs(offset) * 0.5);
        float3 colour = mix(flat, scanned, scanlineStrength);

        // Aperture grille, when there's room for it.
        if (pixelsPerLine >= 3) {
            uint stripe = uint(in.position.x) % 3;
            float3 mask = float3(stripe == 0 ? 1.0 : 0.9, stripe == 1 ? 1.0 : 0.9, stripe == 2 ? 1.0 : 0.9);
            colour *= mask * 1.06;
        }

        // A little vignetting.
        float2 centred = in.uv - 0.5;
        colour *= 1 - dot(centred, centred) * 0.25;

        return float4(pow(saturate(colour), 1 / 2.4), 1);
    }
    """
}
