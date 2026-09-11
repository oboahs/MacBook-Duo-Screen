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
    case blur(String)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "没有可用的 Metal GPU。"
        case .noCommandQueue: return "无法创建 Metal command queue。"
        case .shaderCompilation(let message): return "Metal shader 编译失败：\(message)"
        case .pipeline(let message): return "Metal pipeline 创建失败：\(message)"
        case .textureCache: return "无法创建 CoreVideo / Metal texture cache。"
        case .blur(let message): return "Metal 模糊管线失败：\(message)"
        }
    }
}

/// Inverse-perspective rendering anchored to the bottom hinge. The transformed
/// desktop is surrounded by black. Blur uses a real mip pyramid (like MacDuo)
/// instead of sparse long-distance taps, so the fold defocus stays continuous.
final class PerspectiveRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private let inFlight = DispatchSemaphore(value: 2)

    private var blurPyramid: MTLTexture?
    private var blurLevels: [MTLTexture] = []
    private var blurredRevision: UInt64?

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

        guard let downsample = library.makeFunction(name: "perspectiveDownsample") else {
            throw PerspectiveRenderError.shaderCompilation("找不到 perspectiveDownsample")
        }
        do {
            downsamplePipeline = try device.makeComputePipelineState(function: downsample)
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
        // MacDuo places its overlay above the status-window level. Doing the same
        // here makes the transformed desktop cover the real macOS menu bar instead
        // of leaving that bar visually fixed above the fold animation.
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
                blurredTexture = try prepareBlur(command: command, input: texture, revision: revision)
            } else {
                blurredTexture = texture
            }
        } catch {
            blurredRevision = nil
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
                self?.blurredRevision = nil
                let message = buffer.error?.localizedDescription ?? "Metal rendering failed"
                DispatchQueue.main.async { self?.onFailure?(message) }
            }
        }
        command.present(drawable)
        command.commit()
        committed = true
    }

    /// Build a compact Gaussian-like mip pyramid once per captured desktop frame.
    /// Angle-only changes reuse the same pyramid, which is much cheaper and avoids
    /// the repeated ghost images caused by sparse large-radius taps.
    private func prepareBlur(command: MTLCommandBuffer, input: MTLTexture, revision: UInt64) throws -> MTLTexture {
        if blurPyramid?.width != input.width ||
            blurPyramid?.height != input.height ||
            blurPyramid?.pixelFormat != input.pixelFormat {

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: input.pixelFormat,
                width: input.width,
                height: input.height,
                mipmapped: true
            )
            descriptor.mipmapLevelCount = min(9, descriptor.mipmapLevelCount)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw PerspectiveRenderError.blur("无法创建 blur pyramid")
            }

            var levels: [MTLTexture] = []
            for level in 0..<texture.mipmapLevelCount {
                guard let view = texture.makeTextureView(
                    pixelFormat: texture.pixelFormat,
                    textureType: .type2D,
                    levels: level..<(level + 1),
                    slices: 0..<1
                ) else {
                    throw PerspectiveRenderError.blur("无法创建 mip level \(level)")
                }
                levels.append(view)
            }

            blurPyramid = texture
            blurLevels = levels
            blurredRevision = nil
        }

        if blurredRevision == revision, let pyramid = blurPyramid {
            return pyramid
        }

        guard let pyramid = blurPyramid,
              let blit = command.makeBlitCommandEncoder() else {
            throw PerspectiveRenderError.blur("无法创建 blur copy encoder")
        }

        blit.copy(
            from: input,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: input.width, height: input.height, depth: 1),
            to: pyramid,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin()
        )
        blit.endEncoding()

        for level in 1..<blurLevels.count {
            guard let encoder = command.makeComputeCommandEncoder() else {
                throw PerspectiveRenderError.blur("无法创建 mip encoder")
            }
            encoder.setComputePipelineState(downsamplePipeline)
            encoder.setTexture(blurLevels[level - 1], index: 0)
            encoder.setTexture(blurLevels[level], index: 1)
            encoder.dispatchThreads(
                MTLSize(width: blurLevels[level].width, height: blurLevels[level].height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
        }

        blurredRevision = revision
        return pyramid
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

    // Same deterministic 3x3 binomial-style downsample strategy used by MacDuo.
    // Each mip level is a progressively smoother version of the captured desktop.
    kernel void perspectiveDownsample(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::write> target [[texture(1)]],
        uint2 pixel [[thread_position_in_grid]])
    {
        if (pixel.x >= target.get_width() || pixel.y >= target.get_height()) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(pixel) + 0.5f) / float2(target.get_width(), target.get_height());
        float2 texel = 1.0f / float2(source.get_width(), source.get_height());
        const float offset[3] = { -1.2f, 0.0f, 1.2f };
        const float weight[3] = { 0.3125f, 0.375f, 0.3125f };
        float4 color = 0.0f;
        for (uint y = 0; y < 3; y++) {
            for (uint x = 0; x < 3; x++) {
                color += source.sample(s, uv + float2(offset[x], offset[y]) * texel) * weight[x] * weight[y];
            }
        }
        target.write(color, pixel);
    }

    static float3 sampleMipBlur(
        texture2d<float> desktop,
        texture2d<float> pyramid,
        sampler s,
        float2 uv,
        float sigmaUV)
    {
        if (!(sigmaUV > 0.0f)) return desktop.sample(s, uv).rgb;
        float sigma = sigmaUV * float(desktop.get_height());
        // Each 2x level contributes approximately 1.25 source-pixel variance.
        float lod = 0.5f * log2(1.0f + sigma * sigma * 2.4f);
        lod = min(lod, float(pyramid.get_num_mip_levels() - 1));
        return pyramid.sample(s, uv, level(lod)).rgb;
    }

    fragment float4 perspectiveFragment(
        Varying in [[stage_in]],
        texture2d<float> desktop [[texture(0)]],
        texture2d<float> pyramid [[texture(1)]],
        constant Uniforms& u [[buffer(0)]])
    {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

        float p = clamp(u.amount, 0.0f, 1.0f);
        if (p < 0.00001f) {
            return float4(desktop.sample(s, in.uv).rgb, 1.0f);
        }

        // Distance from the physical bottom hinge: 0 at bottom, 1 at top.
        float height = 1.0f - in.uv.y;
        float perspective = clamp(u.perspective, 0.0f, 1.0f);
        float softness = clamp(u.softness, 0.0f, 1.0f);

        // Keep our inverse-perspective direction: bottom is anchored while the
        // upper desktop contracts inward as the physical lid closes.
        float verticalScale = max(0.50f, 1.0f - p * mix(0.12f, 0.34f, perspective));
        float sourceHeight = height / verticalScale;
        float sourceH = clamp(sourceHeight, 0.0f, 1.0f);
        float taper = p * mix(0.08f, 0.30f, perspective);
        float horizontalScale = max(0.50f, 1.0f - taper * sourceH);
        float sourceX = 0.5f + (in.uv.x - 0.5f) / horizontalScale;
        float2 sourceUV = float2(sourceX, 1.0f - sourceHeight);

        // The blur field starts at the top and advances toward the hinge. The
        // transition is intentionally broad; mip LOD interpolation keeps it free
        // of visible bands or duplicated edges.
        float closeProgress = pow(p, 0.66f);
        float blurFront = 1.0f - closeProgress;
        float frontFeather = 0.24f + 0.14f * softness;
        float frontAmount = smoothstep(
            blurFront - frontFeather,
            blurFront + frontFeather,
            sourceH
        );

        // MacDuo-style continuous sigma: stronger toward the top, but the hinge
        // is never an abrupt sharp/blur boundary. Standard softness stays subtle.
        float focus = pow(p, 0.70f);
        float verticalSpread = 0.12f + 0.88f * pow(sourceH, 1.15f);
        float advancingSpread = mix(0.24f, 1.0f, frontAmount);
        float sigmaUV = softness * 0.052f * focus * verticalSpread * advancingSpread;

        float3 color = sampleMipBlur(desktop, pyramid, s, sourceUV, sigmaUV);

        // Black surround with a soft, blur-aware trapezoid edge. This keeps the
        // fold silhouette clean without the hard cut-out look.
        float edge = 0.0035f + 0.012f * softness + 1.25f * sigmaUV;
        float halfWidth = 0.5f * horizontalScale;
        float horizontalDistance = abs(in.uv.x - 0.5f);
        float insideX = 1.0f - smoothstep(max(0.0f, halfWidth - edge), halfWidth, horizontalDistance);
        float insideTop = 1.0f - smoothstep(max(0.0f, verticalScale - edge), verticalScale, height);
        float mask = insideX * insideTop;

        if (sourceHeight > 1.001f || sourceX < -0.001f || sourceX > 1.001f) {
            mask = 0.0f;
        }

        float shade = 1.0f - clamp(u.dimming, 0.0f, 1.0f) * 0.12f * p * p * sourceH;
        float disappear = 1.0f - smoothstep(0.90f, 1.0f, p);
        return float4(color * mask * shade * disappear, 1.0f);
    }
    """#
}
