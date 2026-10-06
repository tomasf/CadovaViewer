import SceneKit
import simd

/// GPU side of cross-sections, shared by the app's viewports and the headless renderer: the clip and
/// cap surface shader modifiers, and the plane packing their uniforms expect.
extension CrossSection {
    /// Up to this many simultaneous cutting planes (the clip uniform packs planes into two `float4x4`).
    public static let maxRenderedCount = 8

    /// Surface shader modifier clipping fragments past **any** active plane, and — via the
    /// `materialsEnabled` uniform — overriding the surface when the viewport's materials-enabled
    /// option is off. Face materials go flat opaque matte white; edge-line materials (flagged by the
    /// `isEdgeMaterial` uniform, set once when the modifier is installed) instead
    /// force plain black, since their baked light/dark choice was picked for contrast against the
    /// *original* face colour, which no longer applies once faces turn white. Planes are packed into
    /// two `float4x4` uniforms (columns 0–3 in A, 4–7 in B); `crossSectionSkip` lets a cap skip its
    /// own plane. Attached to every model material while cutting (and, in the headless renderer, also
    /// when materials are off).
    public static let clipShaderModifier = """
    #pragma arguments
    float4x4 crossSectionPlanesA;
    float4x4 crossSectionPlanesB;
    float crossSectionCount;
    float crossSectionSkip;
    float materialsEnabled;
    float isEdgeMaterial;
    #pragma body
    int csCount = int(round(crossSectionCount));
    if (csCount > 0) {
        int csSkip = int(round(crossSectionSkip));
        float3 csWorld = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
        for (int i = 0; i < csCount; i++) {
            if (i == csSkip) continue;
            float4 csPlane = (i < 4) ? crossSectionPlanesA[i] : crossSectionPlanesB[i - 4];
            if (dot(csWorld, csPlane.xyz) > csPlane.w) { discard_fragment(); }
        }
    }
    if (materialsEnabled < 0.5 && isEdgeMaterial > 0.5) {
        _surface.diffuse = float4(0.0, 0.0, 0.0, 1.0);
    } else if (materialsEnabled < 0.5) {
        _surface.diffuse = float4(1.0, 1.0, 1.0, 1.0);
        _surface.metalness = 0.0;
        _surface.roughness = 0.9;
    }
    """

    /// Cap surface modifier: the same N-plane clip (skipping its own plane, so a cap is trimmed by the
    /// *other* cuts) plus the part colour and a diagonal hatch marking it as a cut face. When the
    /// viewport's materials-enabled option is off, both the base fill and the hatch stripe desaturate
    /// to white/gray (same "no material" look as the model's faces) rather than showing the part or
    /// cross-section colour.
    public static let capShaderModifier = """
    #pragma arguments
    float4x4 crossSectionPlanesA;
    float4x4 crossSectionPlanesB;
    float crossSectionCount;
    float crossSectionSkip;
    float4 capColor;
    float4 capStripeColor;
    float3 hatchDirection;
    float hatchSpacing;
    float hatchStrength;
    float materialsEnabled;
    #pragma body
    float3 csWorld = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    int csCount = int(round(crossSectionCount));
    int csSkip = int(round(crossSectionSkip));
    for (int i = 0; i < csCount; i++) {
        if (i == csSkip) continue;
        float4 csPlane = (i < 4) ? crossSectionPlanesA[i] : crossSectionPlanesB[i - 4];
        if (dot(csWorld, csPlane.xyz) > csPlane.w) { discard_fragment(); }
    }
    bool csMaterialsEnabled = materialsEnabled >= 0.5;
    float3 csBaseColor = csMaterialsEnabled ? capColor.rgb : float3(1.0, 1.0, 1.0);
    float3 csStripeColor = csMaterialsEnabled ? capStripeColor.rgb : float3(0.6, 0.6, 0.6);
    _surface.diffuse = float4(csBaseColor, capColor.a);
    float hatchCoordinate = dot(csWorld, hatchDirection) / hatchSpacing;
    if (fract(hatchCoordinate) < 0.5) {
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, csStripeColor, hatchStrength);
    }
    """

    /// A diagonal direction lying in this section's plane, for the cap hatch.
    public var hatchDirection: SIMD3<Float> {
        let normal = SIMD3<Float>(self.normal)
        let reference = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let u = simd_normalize(simd_cross(reference, normal))
        let v = simd_cross(normal, u)
        return simd_normalize(u + v)
    }

    /// The cap hatch's stripe spacing in millimetres for a model of the given size, so the hatch reads
    /// at the same density on any model.
    public static func hatchSpacing(forModelSize size: SIMD3<Double>) -> Float {
        Float(max(size.max() / 90, 0.3))
    }

    /// Clip planes packed for the shader modifiers' uniforms: two `float4x4` of planes (columns 0–3 in
    /// `a`, 4–7 in `b`) plus the active count. Sections past `maxRenderedCount` are dropped.
    public struct PackedPlanes {
        public let a: SCNMatrix4
        public let b: SCNMatrix4
        public let count: Int

        public init(_ sections: [CrossSection]) {
            let planes = sections.prefix(CrossSection.maxRenderedCount).map { section -> SIMD4<Float> in
                let p = section.plane()
                return SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), Float(p.w))
            }
            func column(_ i: Int) -> SIMD4<Float> { i < planes.count ? planes[i] : .zero }
            a = SCNMatrix4(simd_float4x4(column(0), column(1), column(2), column(3)))
            b = SCNMatrix4(simd_float4x4(column(4), column(5), column(6), column(7)))
            count = planes.count
        }

        /// Pushes the planes to a material using `clipShaderModifier` or `capShaderModifier`. `skip` is
        /// the index of a plane to ignore (a cap's own plane), or -1 for none.
        public func apply(to material: SCNMaterial, skip: Int) {
            material.setValue(NSValue(scnMatrix4: a), forKey: "crossSectionPlanesA")
            material.setValue(NSValue(scnMatrix4: b), forKey: "crossSectionPlanesB")
            material.setValue(NSNumber(value: Float(count)), forKey: "crossSectionCount")
            material.setValue(NSNumber(value: Float(skip)), forKey: "crossSectionSkip")
        }
    }
}
