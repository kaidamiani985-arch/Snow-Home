import simd

/// Per-instance data for one falling flake.
/// Layout must match `FlakeInstance` in Shaders.swift (stride 24).
struct FlakeInstance {
    var pos: SIMD2<Float>
    var size: Float
    var alpha: Float
    var rot: Float
    var seed: Float
}

/// One vertex of an accumulated-snow strip.
/// `par` = 0 at the base of the drift, 1 at the snow surface, >1 on the lit crest.
/// Layout must match `DriftVertex` in Shaders.swift (stride 16).
struct DriftVertex {
    var pos: SIMD2<Float>
    var par: Float
    var alpha: Float
}

struct Uniforms {
    var size: SIMD2<Float>
    var time: Float
    var pad: Float
}
