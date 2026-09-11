import AppKit
import MetalKit
import MetalPerformanceShaders
import CoreVideo
import Foundation

struct PerspectiveUniforms {
    var amount: Float = 0
    var perspective: Float = 0.75
    var softness: Float = 0.60
    var dimming: Float = 0.15
    var size = SIMD2<Float>(1, 1)
    // padding.x is the independent geometry/compensation strength multiplier.
    var padding = SIMD2<Float>(1, 0)
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
    case blur(String)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "没有可用的 Metal GPU。"
        case .noCommandQueue: return "无法创建 Metal command queue。"
        case .shaderCompilation(let message): return "Metal shader 编译失败：\(message)"
        case .pipeline(let message): return "Metal pipeline 创建失败：\(message)"
        case .textureCache: return "无法创建 CoreVideo / Metal texture cache。"
        case .blur(let message): return "高斯模糊管线失败：\(message)"
        }
    }
}

/// Inverse-perspective rendering anchored to the bottom hinge.
/// A full-resolution MPSImageGaussianBlur is generated on the GPU for each new
/// captured frame, then blended from top to bottom as the lid closes. This avoids
/// the repeated-edge/ghosting artifacts produced by sparse long-distance taps.
final class PerspectiveRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let inFlight = DispatchSemaphore(value: 2)

    private var gaussianTexture: MTLTexture?
    private var gaussianFilter: MPSImageGaussianBlur?
    private var gaussianSigma: Float = -1
    private var gaussianRevision: UInt64?

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
        if let window = view.window {
            let targetLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
            if window.level != targetLevel { window.level = targetLevel }
        }

        guard inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }

        guard let stored = frames?.get(), let pixelBuffer = stored.0,
              let textureCache else { return }
        let revision = stored.1

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
              let command = commandQueue.makeCommandBuffer() else {
            return
        }

        var uniforms = parameters()
        uniforms.size = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))

        let blurredTexture: MTLTexture
        do {
            if uniforms.amount > 0.00001, uniforms.softness > 0.00001 {
                // 0...1 blur control maps to a visibly strong 0...64 px Gaussian sigma.
                // The angle controls where/how much of this blurred frame is mixed in.
                let sigma = max(0.01, uniforms.softness * 64.0)
                blurredTexture = try prepareGaussian(
                    command: command,
                    input: texture,
                    revision: revision,
                    sigma: sigma
                )
            } else {
                blurredTexture = texture
            }
        } catch {
            gaussianRevision = nil
            DispatchQueue.main.async { [weak self] in self?.onFailure?(error.localizedDescription) }
            return
        }

        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(blurredTexture, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PerspectiveUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let retainedPixelBuffer = pixelBuffer
        let retainedCVTexture = cvTexture
        command.addCompletedHandler { [weak self, inFlight] buffer in
            withExtendedLifetime((retainedPixelBuffer, retainedCVTexture)) {}
            inFlight.signal()
            if buffer.status == .error {
                self?.gaussianRevision = nil
                let message = buffer.error?.localizedDescription ?? "Metal rendering failed"
                DispatchQueue.main.async { self?.onFailure?(message) }
            }
        }
        command.present(drawable)
        command.commit()
        committed = true
    }

    private func prepareGaussian(
        command: MTLCommandBuffer,
        input: MTLTexture,
        revision: UInt64,
        sigma: Float
    ) throws -> MTLTexture {
        let needsTexture = gaussianTexture?.width != input.width ||
            gaussianTexture?.height != input.height ||
            gaussianTexture?.pixelFormat != input.pixelFormat

        if needsTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: input.pixelFormat,
                width: input.width,
                height: input.height,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw PerspectiveRenderError.blur("无法创建高斯模糊纹理")
            }
            gaussianTexture = texture
            gaussianRevision = nil
        }

        if gaussianFilter == nil || abs(gaussianSigma - sigma) > 0.01 {
            let filter = MPSImageGaussianBlur(device: device, sigma: sigma)
            filter.edgeMode = .clamp
            gaussianFilter = filter
            gaussianSigma = sigma
            gaussianRevision = nil
        }

        if gaussianRevision == revision, let gaussianTexture {
            return gaussianTexture
        }

        guard let gaussianTexture, let gaussianFilter else {
            throw PerspectiveRenderError.blur("无法初始化 MPSImageGaussianBlur")
        }

        gaussianFilter.encode(
            commandBuffer: command,
            sourceTexture: input,
            destinationTexture: gaussianTexture
        )
        gaussianRevision = revision
        return gaussianTexture
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

    fragment float4 perspectiveFragment(
        Varying in [[stage_in]],
        texture2d<float> desktop [[texture(0)]],
        texture2d<float> gaussian [[texture(1)]],
        constant Uniforms& u [[buffer(0)]])
    {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

        float p = clamp(u.amount, 0.0f, 1.0f);
        if (p < 0.00001f) {
            return float4(desktop.sample(s, in.uv).rgb, 1.0f);
        }

        float height = 1.0f - in.uv.y; // 0 at hinge, 1 at top
        float perspective = clamp(u.perspective, 0.0f, 1.0f);
        float blurStrength = clamp(u.softness, 0.0f, 1.0f);
        float compensationStrength = clamp(u.padding.x, 0.50f, 3.00f);

        // Geometry strength is independent from lid progress. This allows 150–300%
        // compensation without accelerating blur/fade timing or clamping at 100%.
        float g = min(2.6f, p * compensationStrength);
        float verticalScale = max(0.26f, 1.0f - g * mix(0.10f, 0.31f, perspective));
        float sourceHeight = height / verticalScale;
        float sourceH = clamp(sourceHeight, 0.0f, 1.0f);
        float taper = g * mix(0.07f, 0.28f, perspective);
        float horizontalScale = max(0.28f, 1.0f - taper * sourceH);
        float sourceX = 0.5f + (in.uv.x - 0.5f) / horizontalScale;
        float2 sourceUV = float2(sourceX, 1.0f - sourceHeight);

        // A broad blur front starts at the top and travels toward the hinge.
        // The Gaussian kernel itself is full-resolution MPS; this mask only controls
        // the natural top-to-bottom blend between sharp and Gaussian-blurred frames.
        float closeProgress = pow(p, 0.58f);
        float blurFront = mix(0.96f, 0.01f, closeProgress);
        float feather = 0.19f + 0.18f * blurStrength + 0.05f * closeProgress;
        float blurField = smoothstep(
            blurFront - feather,
            blurFront + feather,
            sourceH
        );
        float blurPresence = smoothstep(0.006f, 0.105f, p);
        float blurMix = clamp(blurField * blurPresence, 0.0f, 1.0f);

        float3 sharp = desktop.sample(s, sourceUV).rgb;
        float3 blurred = gaussian.sample(s, sourceUV).rgb;
        float3 color = mix(sharp, blurred, blurMix);

        // Keep the transformed desktop surrounded by black and feather its edge.
        float edge = 0.0035f + 0.012f * blurStrength + 0.003f * p;
        float halfWidth = 0.5f * horizontalScale;
        float horizontalDistance = abs(in.uv.x - 0.5f);
        float insideX = 1.0f - smoothstep(max(0.0f, halfWidth - edge), halfWidth, horizontalDistance);
        float insideTop = 1.0f - smoothstep(max(0.0f, verticalScale - edge), verticalScale, height);
        float mask = insideX * insideTop;

        if (sourceHeight > 1.001f || sourceX < -0.001f || sourceX > 1.001f) {
            mask = 0.0f;
        }

        float shade = 1.0f - clamp(u.dimming, 0.0f, 1.0f) * 0.15f * p * p * sourceH;
        float disappear = 1.0f - smoothstep(0.92f, 1.0f, p);
        return float4(color * mask * shade * disappear, 1.0f);
    }
    """#
}
