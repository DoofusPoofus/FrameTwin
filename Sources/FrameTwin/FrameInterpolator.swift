/*
 frame interpolator
 give it evry new real frame in order and it writes the frame that goes between the last one and this one
 it keeps a grayscale pyramid (1/4 1/8 1/16 size) of the last frame so each frame only gets shrunk once
 the motion search starts at the tiny 1/16 level with a wide search and then gets refined on the bigger levels
 all the gpu work goes into the command buffer u pass in. nothing runs til u commit it
*/

import Metal

final class FrameInterpolator {
    struct SearchSettings {
        var searchRadius: Int32
        var patchRadius: Int32
        var useGuide: Int32
        var smoothnessPenalty: Float
    }

    struct BlendSettings {
        var flowScale: SIMD2<Float>
        var mismatchFalloff: Float
    }

    enum SetupError: Error {
        case missingKernel(String)
    }

    var mismatchFalloff: Float = 2.5

    private let device: MTLDevice
    private let lumaQuarterPipeline: MTLComputePipelineState
    private let lumaHalfPipeline: MTLComputePipelineState
    private let symmetricSearchPipeline: MTLComputePipelineState
    private let smoothFlowPipeline: MTLComputePipelineState
    private let warpBlendPipeline: MTLComputePipelineState

    private var preparedWidth = 0
    private var preparedHeight = 0
    private var previousPyramid: [MTLTexture] = []
    private var currentPyramid: [MTLTexture] = []
    private var motionLevels: [MTLTexture] = []
    private var smoothedMotion: MTLTexture?
    private var hasPreviousPyramid = false

    private let searchSettingsPerLevel: [SearchSettings] = [
        SearchSettings(searchRadius: 2, patchRadius: 2, useGuide: 1, smoothnessPenalty: 0.02),
        SearchSettings(searchRadius: 2, patchRadius: 2, useGuide: 1, smoothnessPenalty: 0.02),
        SearchSettings(searchRadius: 6, patchRadius: 2, useGuide: 0, smoothnessPenalty: 0.03),
    ]

    init(device: MTLDevice) throws {
        self.device = device
        let shaderLibrary = try device.makeLibrary(source: interpolationShaderSource, options: nil)

        func makePipeline(_ kernelName: String) throws -> MTLComputePipelineState {
            guard let kernelFunction = shaderLibrary.makeFunction(name: kernelName) else {
                throw SetupError.missingKernel(kernelName)
            }
            return try device.makeComputePipelineState(function: kernelFunction)
        }

        lumaQuarterPipeline = try makePipeline("lumaQuarter")
        lumaHalfPipeline = try makePipeline("lumaHalf")
        symmetricSearchPipeline = try makePipeline("symmetricSearch")
        smoothFlowPipeline = try makePipeline("smoothFlow")
        warpBlendPipeline = try makePipeline("warpBlend")
    }

    func forgetPreviousFrame() {
        hasPreviousPyramid = false
    }

    @discardableResult
    func encodeMiddleFrame(newFrame: MTLTexture,
                           previousFrame: MTLTexture?,
                           middleFrame: MTLTexture,
                           commandBuffer: MTLCommandBuffer) -> Bool {
        if newFrame.width != preparedWidth || newFrame.height != preparedHeight {
            prepareTextures(width: newFrame.width, height: newFrame.height)
        }

        swap(&previousPyramid, &currentPyramid)
        let canInterpolate = hasPreviousPyramid && previousFrame != nil
        hasPreviousPyramid = true

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }

        dispatch(encoder, lumaQuarterPipeline, textures: [newFrame, currentPyramid[0]], size: currentPyramid[0])
        dispatch(encoder, lumaHalfPipeline, textures: [currentPyramid[0], currentPyramid[1]], size: currentPyramid[1])
        dispatch(encoder, lumaHalfPipeline, textures: [currentPyramid[1], currentPyramid[2]], size: currentPyramid[2])

        guard canInterpolate, let previousFrame, let smoothedMotion else {
            encoder.endEncoding()
            return false
        }

        for level in stride(from: motionLevels.count - 1, through: 0, by: -1) {
            var settings = searchSettingsPerLevel[level]
            let coarserMotion = level + 1 < motionLevels.count ? motionLevels[level + 1] : smoothedMotion
            encoder.setComputePipelineState(symmetricSearchPipeline)
            encoder.setTexture(previousPyramid[level], index: 0)
            encoder.setTexture(currentPyramid[level], index: 1)
            encoder.setTexture(coarserMotion, index: 2)
            encoder.setTexture(motionLevels[level], index: 3)
            encoder.setBytes(&settings, length: MemoryLayout<SearchSettings>.stride, index: 0)
            dispatchThreads(encoder, symmetricSearchPipeline, for: motionLevels[level])
        }

        dispatch(encoder, smoothFlowPipeline, textures: [motionLevels[0], smoothedMotion], size: smoothedMotion)

        var blendSettings = BlendSettings(
            flowScale: SIMD2(Float(middleFrame.width) / Float(smoothedMotion.width),
                             Float(middleFrame.height) / Float(smoothedMotion.height)),
            mismatchFalloff: mismatchFalloff
        )
        encoder.setComputePipelineState(warpBlendPipeline)
        encoder.setTexture(previousFrame, index: 0)
        encoder.setTexture(newFrame, index: 1)
        encoder.setTexture(smoothedMotion, index: 2)
        encoder.setTexture(middleFrame, index: 3)
        encoder.setBytes(&blendSettings, length: MemoryLayout<BlendSettings>.stride, index: 0)
        dispatchThreads(encoder, warpBlendPipeline, for: middleFrame)

        encoder.endEncoding()
        return true
    }

    private func prepareTextures(width: Int, height: Int) {
        preparedWidth = width
        preparedHeight = height
        hasPreviousPyramid = false

        var levelSizes: [(Int, Int)] = []
        var levelWidth = (width + 3) / 4
        var levelHeight = (height + 3) / 4
        for _ in 0..<3 {
            levelSizes.append((max(levelWidth, 1), max(levelHeight, 1)))
            levelWidth = (levelWidth + 1) / 2
            levelHeight = (levelHeight + 1) / 2
        }

        previousPyramid = levelSizes.map { makeWorkTexture(width: $0.0, height: $0.1, format: .r16Float) }
        currentPyramid = levelSizes.map { makeWorkTexture(width: $0.0, height: $0.1, format: .r16Float) }
        motionLevels = levelSizes.map { makeWorkTexture(width: $0.0, height: $0.1, format: .rgba32Float) }
        smoothedMotion = makeWorkTexture(width: levelSizes[0].0, height: levelSizes[0].1, format: .rgba32Float)
    }

    private func makeWorkTexture(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)!
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder,
                          _ pipeline: MTLComputePipelineState,
                          textures: [MTLTexture],
                          size sizeTexture: MTLTexture) {
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        dispatchThreads(encoder, pipeline, for: sizeTexture)
    }

    private func dispatchThreads(_ encoder: MTLComputeCommandEncoder,
                                 _ pipeline: MTLComputePipelineState,
                                 for texture: MTLTexture) {
        let groupWidth = pipeline.threadExecutionWidth
        let groupHeight = max(pipeline.maxTotalThreadsPerThreadgroup / groupWidth, 1)
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: groupWidth, height: min(groupHeight, 16), depth: 1))
    }
}
