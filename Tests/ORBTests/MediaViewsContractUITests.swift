import Foundation
import Testing
@testable import ORB

@Suite("Media studio controls")
struct MediaViewsContractUITests {
    private func endpoint(_ slug: String, _ parameters: [String: ImageEndpointCapability],
                          tag: String? = nil) throws -> ImageModelEndpoint {
        let descriptors: [String: [String: Any]] = parameters.mapValues { capability in
            switch capability {
            case .enumValues(let values): return ["type": "enum", "values": values]
            case .range(let min, let max): return ["type": "range", "min": min, "max": max]
            case .boolean: return ["type": "boolean"]
            case .unknown(let type): return ["type": type]
            }
        }
        let json = try JSONSerialization.data(withJSONObject: [
            "provider_name": slug, "provider_slug": slug, "provider_tag": tag as Any? ?? NSNull(),
            "supported_parameters": descriptors, "allowed_passthrough_parameters": [],
            "supports_streaming": false, "pricing": []
        ])
        return try JSONDecoder().decode(ImageModelEndpoint.self, from: json)
    }

    @Test func unpinnedControlsUseOnlyCommonEndpointCapabilities() throws {
        let a = try endpoint("a", ["n": .range(min: 1, max: 16), "resolution": .enumValues(["1K", "2K"]), "seed": .boolean])
        let b = try endpoint("b", ["n": .range(min: 1, max: 3), "resolution": .enumValues(["2K", "4K"])])
        let capabilities = ImageStudioCapabilities(endpoints: [a, b], pinnedSlug: nil)
        #expect(capabilities.maximumCount == 3)
        #expect(capabilities.options("resolution") == ["auto", "2K"])
        #expect(!capabilities.supports("seed"))
        #expect(capabilities.referenceLimit == 0)
        #expect(capabilities.referenceError(count: 1) != nil)
    }

    @Test func pinOnlyWhenSlugSelectsExactlyOneEndpoint() throws {
        let a = try endpoint("same", ["n": .range(min: 1, max: 16)])
        let b = try endpoint("same", ["n": .range(min: 1, max: 2)])
        let capabilities = ImageStudioCapabilities(endpoints: [a, b], pinnedSlug: "same")
        #expect(capabilities.pinnedSlug == nil)
        #expect(capabilities.maximumCount == 2)
        let unique = ImageStudioCapabilities(endpoints: [a, try endpoint("other", [:])], pinnedSlug: "same")
        #expect(unique.pinnedSlug == "same")
        #expect(unique.maximumCount == 10)
    }

    @Test func referenceLimitDoesNotSilentlyDropImages() throws {
        let a = try endpoint("a", ["input_references": .range(min: 0, max: 16)])
        let b = try endpoint("b", ["input_references": .range(min: 0, max: 3)])
        let capabilities = ImageStudioCapabilities(endpoints: [a, b], pinnedSlug: nil)
        #expect(capabilities.referenceLimit == 3)
        #expect(capabilities.referenceError(count: 4) != nil)
        #expect(capabilities.referenceError(count: 3) == nil)
        #expect(ImageStudioCapabilities(endpoints: [], pinnedSlug: nil).referenceError(count: 17) != nil)
    }

    @Test func imageFileConversionRejectsInvalidBytesAndOversize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an image".utf8).write(to: url)
        #expect(throws: Error.self) { try MediaStudioImageFile.dataURL(for: url) }
        try Data(repeating: 0, count: 20_000_001).write(to: url)
        #expect(throws: Error.self) { try MediaStudioImageFile.dataURL(for: url) }
    }

    @Test func providerPinEncodesWithoutFallback() throws {
        var request = ImageGenRequest(model: "image/model", prompt: "portrait")
        request.provider = ImageGenerationProviderPreferences(only: ["provider-slug"], allowFallbacks: false)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let provider = try #require(object["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["provider-slug"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
    }

    @Test func videoRequestEncodesDisabledAudioAndTypedFrames() throws {
        var request = VideoGenRequest(model: "video/model")
        request.generateAudio = false
        request.firstFrameImage = "data:image/png;base64,AAAA"
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(object["generate_audio"] as? Bool == false)
        let frames = try #require(object["frame_images"] as? [[String: Any]])
        #expect(frames.first?["frame_type"] as? String == "first_frame")
        #expect(frames.first?["type"] as? String == "image_url")
        #expect((frames.first?["image_url"] as? [String: String])?["url"] == request.firstFrameImage)
    }
}
