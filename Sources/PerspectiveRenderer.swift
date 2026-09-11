import AppKit
import MetalKit
import CoreVideo
import Foundation

struct PerspectiveUniforms {
    var amount: Float = 0
    var perspective: Float = 0.75
    var softness: Float = 0.25
    var dimming: Float = 0.15
    var size = SIMD2<Float>(1, 1)
    var padding = SIMD2<Float>(0, 0)
}

final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var revision: UInt64 = 0

    func put(_ value: CVPixelBuffer) {
        lock.lock()
        buffer = value
        revision &+= 1
        lock.unlock()
    }

    func get() -> (CVPixelBuffer?, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (buffer, revision)
    }

    func clear() {
        lock.lock()
        buffer = nil
        revision &+= 1
        lock.unlock()
    }
}

enum PerspectiveRenderError: LocalizedError {
    case noMetalDevice
    case noCommandQueue
    case shaderCompilation(String)
    case pipeline(String)
    case textureCache

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "没有可用的 Metal GPU。"
        case .noCommandQueue: return "无法创建 Metal command queue。"
        case .shaderCompilation(let message): return "Metal shader 编译失败：\(message)"
        case .pipeline(let message): return "Metal pipeline 创建失败：\(message)"
        case .textureCache: return "无法创建 CoreVideo / Metal texture cache。"
        }
    }
}

/// Inverse-perspective rendering anchored to the bottom hinge. The foreground
/// desktop contracts into a trapezoid while a vertically advancing blur field
/// replaces the old black surround and gradually covers the whole display.
final class PerspectiveRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let inFlight = DispatchSemaphore(value: 2)

    var frames: FrameStore?
    var parameters: () -> PerspectiveUniforms = { PerspectiveUniforms() }
    var onFailure: ((String) -> Void)?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw PerspectiveRenderError.noMetalDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw PerspectiveRenderError.noCommandQueue }
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw PerspectiveRenderError.shaderCompilation(error.localizedDescription)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "perspectiveVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "perspectiveFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw PerspectiveRenderError.pipeline(error.localizedDescription)
        }

        super.init()
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else {
            throw PerspectiveRenderError.textureCache
        }
    }

    func configure(_ view: MTKView, fps: Int) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = max(30, min(fps, 60))
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }

        guard let stored = frames?.get(), let pixelBuffer = stored.0,
              let textureCache else { return }

        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let cvResult = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard cvResult == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }

        var uniforms = parameters()
        uniforms.size = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PerspectiveUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let retainedPixelBuffer = pixelBuffer
        let retainedCVTexture = cvTexture
        command.addCompletedHandler { [weak self, inFlight] buffer in
            withExtendedLifetime((retainedPixelBuffer, retainedCVTexture)) {}
            inFlight.signal()
            if buffer.status == .error {
                let message = buffer.error?.localizedDescription ?? "Metal rendering failed"
                DispatchQueue.main.async { self?.onFailure?(message) }
            }
        }
        command.present(drawable)
        command.commit()
        committed = true
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float amount;
        float perspective;
        float softness;
        float dimming;
        float2 size;
        float2 padding;
    };

    struct Varying {
        float4 position [[position]];
        float2 uv;
    };

    vertex Varying perspectiveVertex(uint id [[vertex_id]]) {
        const float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        Varying out;
        out.position = float4(p[id], 0, 1);
        out.uv = float2((p[id].x + 1.0f) * 0.5f, 1.0f - (p[id].y + 1.0f) * 0.5f);
        return out;
    }

    static float3 sampleBlurred(
        texture2d<float> image,
        sampler s,
        float2 uv,
        float radius)
    {
        if (radius <= 0.05f) return image.sample(s, uv).rgb;

        float2 texel = 1.0f / float2(image.get_width(), image.get_height());
        float2 o = texel * radius;
        float3 c = image.sample(s, uv).rgb * 0.25f;
        c += image.sample(s, uv + float2( o.x, 0.0f)).rgb * 0.125f;
        c += image.sample(s, uv + float2(-o.x, 0.0f)).rgb * 0.125f;
        c += image.sample(s, uv + float2(0.0f,  o.y)).rgb * 0.125f;
        c += image.sample(s, uv + float2(0.0f, -o.y)).rgb * 0.125f;
        c += image.sample(s, uv + float2( o.x,  o.y)).rgb * 0.0625f;
        c += image.sample(s, uv + float2(-o.x,  o.y)).rgb * 0.0625f;
        c += image.sample(s, uv + float2( o.x, -o.y)).rgb * 0.0625f;
        c += image.sample(s, uv + float2(-o.x, -o.y)).rgb * 0.0625f;
        return c;
    }

    fragment float4 perspectiveFragment(
        Varying in [[stage_in]],
        texture2d<float> desktop [[texture(0)]],
        constant Uniforms& u [[buffer(0)]])
    {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

        float p = clamp(u.amount, 0.0f, 1.0f);
        if (p < 0.00001f) {
            return float4(desktop.sample(s, in.uv).rgb, 1.0f);
        }

        // height = distance from the bottom hinge: 0 at hinge, 1 at top.
        float height = 1.0f - in.uv.y;
        float perspective = clamp(u.perspective, 0.0f, 1.0f);
        float softness = clamp(u.softness, 0.0f, 1.0f);

        // The blur front begins at the top and travels downward as the lid closes.
        // pow(p, 0.58) makes the first part visible early without making the final
        // transition snap. Standard softness (.25) maps to a 1x blur multiplier.
        float blurReach = clamp(pow(p, 0.58f), 0.0f, 1.0f);
        float blurFront = 1.0f - blurReach;
        float frontFeather = 0.045f + 0.11f * softness;
        float blurMask = smoothstep(blurFront - frontFeather, blurFront + frontFeather, height);
        float blurMultiplier = softness > 0.001f ? softness / 0.25f : 0.0f;
        float maxRadius = (2.0f + 17.0f * pow(p, 0.72f)) * blurMultiplier;
        float backgroundRadius = maxRadius * blurMask * 1.15f;

        // Full-screen blurred desktop replaces the old black surround. It is only
        // strongly blurred above the moving front; below that it stays near sharp.
        float3 background = sampleBlurred(desktop, s, in.uv, backgroundRadius);
        background *= 1.0f - clamp(u.dimming, 0.0f, 1.0f) * 0.10f * p * blurMask;

        // Inverse perspective around the bottom-center hinge.
        float verticalScale = max(0.50f, 1.0f - p * mix(0.12f, 0.34f, perspective));
        float sourceHeight = height / verticalScale;
        float taper = p * mix(0.08f, 0.30f, perspective);
        float horizontalScale = max(0.50f, 1.0f - taper * clamp(sourceHeight, 0.0f, 1.0f));
        float sourceX = 0.5f + (in.uv.x - 0.5f) / horizontalScale;
        float2 sourceUV = float2(sourceX, 1.0f - sourceHeight);

        // Soft trapezoid boundary for blending foreground into the blurred surround.
        float edge = 0.0015f + 0.010f * softness;
        float halfWidth = 0.5f * horizontalScale;
        float horizontalDistance = abs(in.uv.x - 0.5f);
        float insideX = 1.0f - smoothstep(max(0.0f, halfWidth - edge), halfWidth, horizontalDistance);
        float insideTop = 1.0f - smoothstep(max(0.0f, verticalScale - edge), verticalScale, height);
        float mask = insideX * insideTop;

        if (mask <= 0.0001f || sourceHeight > 1.001f || sourceX < -0.001f || sourceX > 1.001f) {
            return float4(background, 1.0f);
        }

        // Apply the same top-to-bottom blur front to transformed content itself.
        float sourceBlurMask = smoothstep(
            blurFront - frontFeather,
            blurFront + frontFeather,
            clamp(sourceHeight, 0.0f, 1.0f)
        );
        float contentRadius = maxRadius * sourceBlurMask;
        float3 content = sampleBlurred(desktop, s, sourceUV, contentRadius);
        float shade = 1.0f - clamp(u.dimming, 0.0f, 1.0f) * 0.08f * p * clamp(sourceHeight, 0.0f, 1.0f);
        content *= shade;

        float3 composed = mix(background, content, mask);
        return float4(composed, 1.0f);
    }
    """#
}
