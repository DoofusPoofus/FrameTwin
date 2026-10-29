/*
 the metal shaders for making the in between frame
 they get compiled when the app starts so we dont need a metallib build step

 lumaQuarter + lumaHalf   shrink a frame to grayscale at 1/4 then 1/8 then 1/16 size
 symmetricSearch          for evry pixel try a bunch of motions and keep the one where both frames match best
                          frame A gets moved back half the motion and frame B forward half
                          so the result is already the motion at the middle moment
 smoothFlow               cleans up the motion so single bad pixels dont stick out
 warpBlend                moves both full size frames by half the motion and blends them
                          where they still dont agree it falls back to the newest real frame
*/

let interpolationShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct SearchSettings {
    int searchRadius;
    int patchRadius;
    int useGuide;
    float smoothnessPenalty;
};

struct BlendSettings {
    float2 flowScale;
    float mismatchFalloff;
};

constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

kernel void lumaQuarter(texture2d<float, access::read> fullFrame [[texture(0)]],
                        texture2d<float, access::write> quarterLuma [[texture(1)]],
                        uint2 position [[thread_position_in_grid]]) {
    if (position.x >= quarterLuma.get_width() || position.y >= quarterLuma.get_height()) return;
    uint2 corner = position * 4;
    uint2 lastPixel = uint2(fullFrame.get_width() - 1, fullFrame.get_height() - 1);
    float brightnessSum = 0.0;
    for (uint y = 0; y < 4; y++) {
        for (uint x = 0; x < 4; x++) {
            float3 color = fullFrame.read(min(corner + uint2(x, y), lastPixel)).rgb;
            brightnessSum += dot(color, float3(0.299, 0.587, 0.114));
        }
    }
    quarterLuma.write(float4(brightnessSum / 16.0), position);
}

kernel void lumaHalf(texture2d<float, access::read> finerLuma [[texture(0)]],
                     texture2d<float, access::write> coarserLuma [[texture(1)]],
                     uint2 position [[thread_position_in_grid]]) {
    if (position.x >= coarserLuma.get_width() || position.y >= coarserLuma.get_height()) return;
    uint2 corner = position * 2;
    uint2 lastPixel = uint2(finerLuma.get_width() - 1, finerLuma.get_height() - 1);
    float brightnessSum = finerLuma.read(min(corner, lastPixel)).r
                        + finerLuma.read(min(corner + uint2(1, 0), lastPixel)).r
                        + finerLuma.read(min(corner + uint2(0, 1), lastPixel)).r
                        + finerLuma.read(min(corner + uint2(1, 1), lastPixel)).r;
    coarserLuma.write(float4(brightnessSum * 0.25), position);
}

kernel void symmetricSearch(texture2d<float, access::sample> previousLuma [[texture(0)]],
                            texture2d<float, access::sample> currentLuma [[texture(1)]],
                            texture2d<float, access::sample> coarserMotion [[texture(2)]],
                            texture2d<float, access::write> motionOut [[texture(3)]],
                            constant SearchSettings& settings [[buffer(0)]],
                            uint2 position [[thread_position_in_grid]]) {
    uint levelWidth = motionOut.get_width();
    uint levelHeight = motionOut.get_height();
    if (position.x >= levelWidth || position.y >= levelHeight) return;

    float2 pixelToUV = 1.0 / float2(levelWidth, levelHeight);
    float2 pixelCenter = float2(position) + 0.5;

    float2 startingMotion = float2(0.0);
    if (settings.useGuide != 0) {
        startingMotion = coarserMotion.sample(linearClamp, pixelCenter * pixelToUV).xy * 2.0;
    }

    float bestCost = INFINITY;
    float2 bestMotion = startingMotion;
    for (int stepY = -settings.searchRadius; stepY <= settings.searchRadius; stepY++) {
        for (int stepX = -settings.searchRadius; stepX <= settings.searchRadius; stepX++) {
            float2 tryOffset = float2(stepX, stepY);
            float2 tryMotion = startingMotion + tryOffset;
            float2 halfMotion = tryMotion * 0.5;
            float mismatch = 0.0;
            for (int patchY = -settings.patchRadius; patchY <= settings.patchRadius; patchY++) {
                for (int patchX = -settings.patchRadius; patchX <= settings.patchRadius; patchX++) {
                    float2 samplePoint = pixelCenter + float2(patchX, patchY);
                    float before = previousLuma.sample(linearClamp, (samplePoint - halfMotion) * pixelToUV).r;
                    float after = currentLuma.sample(linearClamp, (samplePoint + halfMotion) * pixelToUV).r;
                    mismatch += abs(before - after);
                }
            }
            mismatch += settings.smoothnessPenalty * length(tryOffset);
            if (mismatch < bestCost) {
                bestCost = mismatch;
                bestMotion = tryMotion;
            }
        }
    }

    int patchSide = settings.patchRadius * 2 + 1;
    motionOut.write(float4(bestMotion, bestCost / float(patchSide * patchSide), 0.0), position);
}

kernel void smoothFlow(texture2d<float, access::read> roughMotion [[texture(0)]],
                       texture2d<float, access::write> smoothMotion [[texture(1)]],
                       uint2 position [[thread_position_in_grid]]) {
    if (position.x >= smoothMotion.get_width() || position.y >= smoothMotion.get_height()) return;
    int2 lastPixel = int2(roughMotion.get_width() - 1, roughMotion.get_height() - 1);
    float4 centerSample = roughMotion.read(position);
    float2 weightedMotion = float2(0.0);
    float totalWeight = 0.0;
    for (int offsetY = -1; offsetY <= 1; offsetY++) {
        for (int offsetX = -1; offsetX <= 1; offsetX++) {
            int2 neighborPixel = clamp(int2(position) + int2(offsetX, offsetY), int2(0), lastPixel);
            float4 neighbor = roughMotion.read(uint2(neighborPixel));
            float trustInMatch = 1.0 / (0.02 + neighbor.z);
            float keepEdges = exp(-length(neighbor.xy - centerSample.xy) * 0.5);
            float weight = trustInMatch * keepEdges;
            weightedMotion += neighbor.xy * weight;
            totalWeight += weight;
        }
    }
    smoothMotion.write(float4(weightedMotion / totalWeight, centerSample.z, 0.0), position);
}

kernel void warpBlend(texture2d<float, access::sample> previousFrame [[texture(0)]],
                      texture2d<float, access::sample> currentFrame [[texture(1)]],
                      texture2d<float, access::sample> motion [[texture(2)]],
                      texture2d<float, access::write> middleFrame [[texture(3)]],
                      constant BlendSettings& settings [[buffer(0)]],
                      uint2 position [[thread_position_in_grid]]) {
    if (position.x >= middleFrame.get_width() || position.y >= middleFrame.get_height()) return;
    float2 frameSize = float2(middleFrame.get_width(), middleFrame.get_height());
    float2 uv = (float2(position) + 0.5) / frameSize;

    float4 motionSample = motion.sample(linearClamp, uv);
    float2 halfMotionUV = 0.5 * motionSample.xy * settings.flowScale / frameSize;

    float4 fromPrevious = previousFrame.sample(linearClamp, uv - halfMotionUV);
    float4 fromCurrent = currentFrame.sample(linearClamp, uv + halfMotionUV);
    float4 blended = mix(fromPrevious, fromCurrent, 0.5);

    float colorMismatch = length(fromPrevious.rgb - fromCurrent.rgb);
    float trust = exp(-(colorMismatch + motionSample.z) * settings.mismatchFalloff);
    float4 newestRealPixel = currentFrame.sample(linearClamp, uv);
    float4 result = mix(newestRealPixel, blended, trust);

    middleFrame.write(float4(result.rgb, 1.0), position);
}
"""
