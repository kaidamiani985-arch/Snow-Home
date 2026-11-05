import Foundation

/// Metal source, compiled at runtime. This machine has only the Command Line
/// Tools (no `metal` offline compiler), so `makeLibrary(source:)` is the way in.
enum Shaders {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 size;
        float time;
        float pad;
    };

    struct FlakeInstance {
        float2 pos;
        float size;
        float alpha;
        float rot;
        float seed;
    };

    struct FlakeOut {
        float4 position [[position]];
        float2 uv;
        float alpha;
        float seed;
    };

    vertex FlakeOut flake_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 constant Uniforms &u [[buffer(0)]],
                                 const device FlakeInstance *instances [[buffer(1)]]) {
        FlakeInstance inst = instances[iid];

        const float2 corners[6] = {
            float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
            float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
        };

        float2 c = corners[vid];
        float s = sin(inst.rot);
        float co = cos(inst.rot);
        float2 r = float2(c.x * co - c.y * s, c.x * s + c.y * co);
        float2 p = inst.pos + r * inst.size;

        float2 ndc = float2(p.x / u.size.x * 2.0 - 1.0,
                            1.0 - p.y / u.size.y * 2.0);

        FlakeOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = c;
        o.alpha = inst.alpha;
        o.seed = inst.seed;
        return o;
    }

    fragment float4 flake_fragment(FlakeOut in [[stage_in]]) {
        // A soft, slightly irregular flake. The rim is not a perfect circle,
        // and the center fades out gradually, so it reads as snow rather than
        // a hard ball or a grain of sand.
        float2 uv = in.uv;
        float ang = atan2(uv.y, uv.x);
        float seedA = in.seed * 6.2831853;
        float wob = 1.0
            + 0.14 * sin(ang * 3.0 + seedA)
            + 0.08 * sin(ang * 7.0 - seedA * 1.7);
        float2 q = uv * float2(0.88, 1.12);
        float r = length(q) / wob;

        // Some flakes get six soft lobes; others stay irregular blobs. This
        // keeps the field from looking like one repeated particle.
        float star = smoothstep(0.68, 0.96, in.seed);
        float lobes = 0.5 + 0.5 * cos(ang * 6.0 + seedA * 0.5);
        float rr = mix(r, r * (0.74 + 0.46 * lobes), star * 0.75);
        if (rr > 1.0) discard_fragment();

        float body = smoothstep(1.0, 0.30, rr);
        float coreEdge = 0.45 + 0.22 * fract(in.seed * 3.7);
        float core = smoothstep(coreEdge, 0.0, rr);
        float3 col = mix(float3(0.82, 0.88, 1.0), float3(1.0), core);

        return float4(col, body * in.alpha);
    }

    struct DriftVertex {
        float2 pos;
        float par;
        float alpha;
    };

    struct DriftOut {
        float4 position [[position]];
        float par;
        float alpha;
        float2 frag;
    };

    vertex DriftOut drift_vertex(uint vid [[vertex_id]],
                                 const device DriftVertex *verts [[buffer(1)]],
                                 constant Uniforms &u [[buffer(0)]]) {
        DriftVertex v = verts[vid];
        float2 ndc = float2(v.pos.x / u.size.x * 2.0 - 1.0,
                            1.0 - v.pos.y / u.size.y * 2.0);

        DriftOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.par = v.par;
        o.alpha = v.alpha;
        o.frag = v.pos;
        return o;
    }

    fragment float4 drift_fragment(DriftOut in [[stage_in]]) {
        float3 base = float3(0.60, 0.70, 0.86);
        float3 mid  = float3(0.92, 0.955, 1.0);
        float3 hi   = float3(1.0, 1.0, 1.0);

        float3 col = mix(base, mid, smoothstep(0.0, 0.80, in.par));
        col = mix(col, hi, smoothstep(0.88, 1.35, in.par));

        float n = fract(sin(dot(in.frag, float2(12.9898, 78.233))) * 43758.5453);
        col *= 0.975 + 0.025 * n;

        return float4(col, in.alpha);
    }
    """#
}
