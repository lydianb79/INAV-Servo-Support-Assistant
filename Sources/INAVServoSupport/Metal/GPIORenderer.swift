import Foundation
import Metal
import MetalKit
import SwiftUI
import simd

/// Per-instance data – layout must match `Instance` in the shader (48 bytes).
struct GPIOInstance {
    var center: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var shape: Float          // 0 = ball, 1 = chip body, 2 = ring
    var pulse: Float          // > 0 animates a glow
    var pad: SIMD2<Float> = .zero
}

/// Uniforms – layout must match `Uniforms` in the shader (16 bytes).
struct GPIOUniforms {
    var viewport: SIMD2<Float>
    var time: Float
    var pad: Float = 0
}

enum GPIOShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance { float2 center; float2 size; float4 color; float shape; float pulse; float2 pad; };
    struct Uniforms { float2 viewport; float time; float pad; };
    struct VOut {
        float4 position [[position]];
        float2 local;
        float2 halfSize;
        float4 color;
        float shape;
        float pulse;
    };

    vertex VOut gpio_vertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            const device Instance *inst [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
        float2 corners[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
                              float2(1.0, -1.0),  float2(1.0, 1.0),  float2(-1.0, 1.0) };
        Instance I = inst[iid];
        float margin = I.pulse > 0.0 ? 1.9 : 1.15;
        float2 halfSize = I.size * 0.5;
        float2 local = corners[vid] * halfSize * margin;
        float2 p = I.center + local;
        VOut o;
        o.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
        o.local = local;
        o.halfSize = halfSize;
        o.color = I.color;
        o.shape = I.shape;
        o.pulse = I.pulse;
        return o;
    }

    static float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    }

    fragment float4 gpio_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float d;
        float3 base = in.color.rgb;
        float alpha = in.color.a;
        if (in.shape < 0.5) {
            // solder ball / pad with a soft specular highlight
            d = length(in.local) - in.halfSize.x;
            float2 n = in.local / max(in.halfSize.x, 1.0);
            float spec = clamp(1.0 - length(n - float2(-0.35, -0.40)) * 1.1, 0.0, 1.0);
            base = base * (0.62 + 0.38 * (1.0 - clamp(length(n), 0.0, 1.0) * 0.7)) + spec * spec * 0.35;
        } else if (in.shape < 1.5) {
            // package body: vertical gradient + bevelled rim + pin-1 dot
            d = sdRoundBox(in.local, in.halfSize, 14.0);
            float g = 0.5 - 0.5 * (in.local.y / max(in.halfSize.y, 1.0));
            base = mix(base * 0.75, base * 1.30, float3(g));
            float rim = smoothstep(-4.0, -0.5, d);
            base = mix(base, float3(0.52, 0.55, 0.60), float3(rim * 0.7));
            float2 dotPos = in.local - float2(-in.halfSize.x + 16.0, -in.halfSize.y + 16.0);
            float dotMask = 1.0 - smoothstep(4.0, 5.5, length(dotPos));
            base = mix(base, base * 0.35, float3(dotMask));
        } else {
            // hover ring
            d = abs(length(in.local) - in.halfSize.x) - 1.4;
        }
        float aa = max(fwidth(d), 0.35);
        float fill = 1.0 - smoothstep(-aa, aa, d);
        float4 col = float4(base * fill * alpha, fill * alpha);
        if (in.pulse > 0.0) {
            float wave = 0.55 + 0.45 * sin(u.time * 4.0);
            float glow = exp(-max(d, 0.0) / max(in.halfSize.x * 0.35, 1.0)) * wave * in.pulse * (1.0 - fill);
            col += float4(in.color.rgb * glow, glow);
        }
        return col;
    }
    """
}

final class GPIORenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var buffer: MTLBuffer?
    private var bufferCount = 0
    private let startTime = Date()
    private(set) var setupError: String?

    var instances: [GPIOInstance] = [] {
        didSet { uploadInstances() }
    }

    func setup(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            setupError = "No Metal device available."
            return
        }
        self.device = device
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.layer?.isOpaque = false
        view.delegate = self
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: GPIOShaders.source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "GPIO map"
            desc.vertexFunction = library.makeFunction(name: "gpio_vertex")
            desc.fragmentFunction = library.makeFunction(name: "gpio_fragment")
            let att = desc.colorAttachments[0]!
            att.pixelFormat = view.colorPixelFormat
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one              // premultiplied alpha
            att.sourceAlphaBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            setupError = "Metal shader compilation failed: \(error.localizedDescription)"
        }
        uploadInstances()
    }

    private func uploadInstances() {
        guard let device = device, !instances.isEmpty else { buffer = nil; bufferCount = 0; return }
        let length = MemoryLayout<GPIOInstance>.stride * instances.count
        buffer = instances.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: length, options: .storageModeShared)
        }
        bufferCount = instances.count
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline = pipeline, let queue = queue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let buffer = buffer, bufferCount > 0 {
            var uniforms = GPIOUniforms(viewport: SIMD2<Float>(Float(max(view.bounds.width, 1)),
                                                               Float(max(view.bounds.height, 1))),
                                        time: Float(Date().timeIntervalSince(startTime)))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<GPIOUniforms>.stride, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<GPIOUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: bufferCount)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

/// MTKView that lets mouse events fall through to the SwiftUI overlay.
final class PassthroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct MetalGPIOView: NSViewRepresentable {
    var instances: [GPIOInstance]

    func makeCoordinator() -> GPIORenderer { GPIORenderer() }

    func makeNSView(context: Context) -> PassthroughMTKView {
        let view = PassthroughMTKView(frame: .zero, device: nil)
        view.wantsLayer = true
        context.coordinator.setup(view: view)
        context.coordinator.instances = instances
        return view
    }

    func updateNSView(_ nsView: PassthroughMTKView, context: Context) {
        context.coordinator.instances = instances
    }
}
