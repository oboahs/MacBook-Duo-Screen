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
/// captured frame. The upper fold edge simultaneously blurs, dissolves and blooms
/// outward into the black surround as the lid closes.
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
        float2 safeUV = clamp(sourceUV, float2(0.0f), float2(1.0f));

        // Gaussian blur front: top first, then progressively toward the hinge.
        float closeProgress = pow(p, 0.58f);
        float blurFront = mix(0.96f, 0.01f, closeProgress);
        float blurFeather = 0.19f + 0.18f * blurStrength + 0.05f * closeProgress;
        float blurField = smoothstep(
            blurFront - blurFeather,
            blurFront + blurFeather,
            sourceH
        );
        float blurPresence = smoothstep(0.006f, 0.105f, p);
        float blurMix = clamp(blurField * blurPresence, 0.0f, 1.0f);

        float3 sharp = desktop.sample(s, safeUV).rgb;
        float3 blurred = gaussian.sample(s, safeUV).rgb;
        float3 color = mix(sharp, blurred, blurMix);

        // The upper edge now dissolves at the same time as it blurs. The dissolve
        // band starts very near the top when the fold begins and travels downward
        // slowly as the lid closes. A wide smoothstep removes any visible cut line.
        float dissolveProgress = pow(p, 0.74f);
        float dissolveFront = mix(0.985f, 0.58f, dissolveProgress);
        float dissolveFeather = 0.10f + 0.20f * blurStrength + 0.08f * dissolveProgress;
        float dissolveField = smoothstep(
            dissolveFront - dissolveFeather,
            dissolveFront + dissolveFeather,
            sourceH
        );
        float dissolveAmount = dissolveField * blurPresence * clamp(0.14f + 0.94f * dissolveProgress, 0.0f, 1.0f);
        float topOpacity = 1.0f - dissolveAmount;

        // Core silhouette. Its own edge is broader than before so the transition
        // starts inside the transformed desktop rather than at a single hard pixel.
        float coreEdge = 0.006f + 0.018f * blurStrength + 0.006f * p;
        float halfWidth = 0.5f * horizontalScale;
        float horizontalDistance = abs(in.uv.x - 0.5f);
        float insideX = 1.0f - smoothstep(
            max(0.0f, halfWidth - coreEdge),
            halfWidth + coreEdge * 0.20f,
            horizontalDistance
        );
        float insideTop = 1.0f - smoothstep(
            max(0.0f, verticalScale - coreEdge * 1.8f),
            verticalScale + coreEdge * 0.15f,
            height
        );

        // Soft source validity replaces the previous hard sourceHeight/sourceX
        // rejection. This is important: the top can fade out instead of snapping.
        float sourceFeather = 0.012f + 0.030f * blurStrength;
        float validLeft = smoothstep(-sourceFeather, sourceFeather, sourceX);
        float validRight = 1.0f - smoothstep(1.0f - sourceFeather, 1.0f + sourceFeather, sourceX);
        float validTop = 1.0f - smoothstep(1.0f - sourceFeather, 1.0f + sourceFeather, sourceHeight);
        float coreMask = insideX * insideTop * validLeft * validRight * validTop;
        float coreAlpha = coreMask * topOpacity;

        // Edge diffusion / bloom. Gaussian pixels are allowed to extend slightly
        // beyond the geometric trapezoid, especially around the upper edge. The
        // expansion grows with blur strength and lid closure, then fades smoothly.
        float diffusionBase = blurPresence
                            * (0.006f + 0.052f * blurStrength)
                            * (0.30f + 0.70f * closeProgress);
        float sideExpansion = diffusionBase * (0.22f + 0.48f * sourceH);
        float topExpansion = diffusionBase * (1.25f + 0.85f * closeProgress);

        float expandedHalfWidth = halfWidth + sideExpansion;
        float haloX = 1.0f - smoothstep(
            max(0.0f, expandedHalfWidth - diffusionBase * 0.45f),
            expandedHalfWidth + diffusionBase * 0.80f,
            horizontalDistance
        );
        float expandedTop = verticalScale + topExpansion;
        float haloTop = 1.0f - smoothstep(
            expandedTop - diffusionBase * 0.55f,
            expandedTop + diffusionBase * 0.95f,
            height
        );

        float haloSourceX = smoothstep(-0.10f, 0.02f, sourceX)
                          * (1.0f - smoothstep(0.98f, 1.10f, sourceX));
        float haloSourceTop = 1.0f - smoothstep(1.00f, 1.16f + 0.10f * blurStrength, sourceHeight);
        float haloMask = haloX * haloTop * haloSourceX * haloSourceTop;
        float edgeBand = max(0.0f, haloMask - coreMask);

        // The halo is strongest where the top is already blurred/dissolving, then
        // falls into black. This creates the soft "evaporating" upper edge instead
        // of a visible border around the warped desktop.
        float haloEnergy = blurMix
                         * (0.16f + 0.44f * blurStrength)
                         * (0.35f + 0.65f * dissolveField);
        float3 diffusedEdge = blurred * edgeBand * haloEnergy;

        float shade = 1.0f - clamp(u.dimming, 0.0f, 1.0f) * 0.15f * p * p * sourceH;
        float disappear = 1.0f - smoothstep(0.92f, 1.0f, p);

        // The panel stays opaque black on purpose. "Transparency" is visual: the
        // transformed image loses energy into black, while a faint Gaussian halo
        // extends beyond the silhouette. Making the NSPanel itself transparent
        // would reveal the untouched desktop underneath and break the illusion.
        float3 composed = color * coreAlpha + diffusedEdge;
        return float4(composed * shade * disappear, 1.0f);
    }
    """#
}
