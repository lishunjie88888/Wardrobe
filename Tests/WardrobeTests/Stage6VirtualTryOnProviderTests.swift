import XCTest
@testable import Wardrobe

final class Stage6VirtualTryOnProviderTests: XCTestCase {
    func testRequestAndVersionedOptionsRoundTripWithoutPaths() throws {
        let request = makeRequest(options: TryOnOptions(
            quality: .high,
            aspectRatio: .portrait,
            seed: 42,
            providerParameters: ["fixture_variant": .string("one")]
        ))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(VirtualTryOnRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.options.schemaVersion, 1)
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(serialized.contains("/Users/"))
        XCTAssertFalse(serialized.contains("file://"))
    }

    func testPromptBuilderIsDeterministicAndVersioned() {
        let request = makeRequest()
        let builder = TryOnPromptBuilder()

        let first = builder.build(garments: request.garments, userInstruction: "  neutral background  ")
        let second = builder.build(garments: Array(request.garments.reversed()), userInstruction: "neutral background")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.version, "wardrobe-try-on-prompt-v1")
        XCTAssertTrue(first.text.contains("upper_body"))
        XCTAssertTrue(first.text.contains("neutral background"))
    }

    func testMockProviderPassesReusableContract() async throws {
        let provider = MockVirtualTryOnProvider()
        try await ProviderContractAssertions.assertValidProvider(provider, request: makeRequest())
    }

    func testMockSuccessIsDeterministic() async throws {
        let request = makeRequest()
        let first = try await MockVirtualTryOnProvider().generate(request: request)
        let second = try await MockVirtualTryOnProvider().generate(request: request)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.imageData, MockVirtualTryOnProvider.fixtureData)
        XCTAssertEqual(first.metadata["mock"], "true")
    }

    func testMockTransientFailureCanBeRetried() async throws {
        let provider = MockVirtualTryOnProvider(behavior: .transientFailures(count: 1))

        await XCTAssertThrowsVirtualTryOnError(.transientFailure) {
            _ = try await provider.generate(request: self.makeRequest())
        }
        let result = try await provider.generate(request: makeRequest())
        XCTAssertEqual(result.imageData, MockVirtualTryOnProvider.fixtureData)
    }

    func testMockPermanentFailureIsStable() async {
        let provider = MockVirtualTryOnProvider(behavior: .permanentFailure())

        await XCTAssertThrowsVirtualTryOnError(.providerUnavailable) {
            _ = try await provider.generate(request: self.makeRequest())
        }
        await XCTAssertThrowsVirtualTryOnError(.providerUnavailable) {
            _ = try await provider.generate(request: self.makeRequest())
        }
    }

    func testMockDelayPropagatesCancellationAndNeverReturnsLateResult() async {
        let provider = MockVirtualTryOnProvider(behavior: .success(delay: .seconds(5)))
        let request = makeRequest()
        let task = Task { try await provider.generate(request: request) }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled generation returned a late result")
        } catch let error as VirtualTryOnError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testValidatorRejectsPersonCountAndMediaType() throws {
        let validator = VirtualTryOnRequestValidator()
        var capabilities = makeCapabilities(maxPersonImages: 1)
        let request = makeRequest(personImages: [makeImage(id: UUID()), makeImage(id: UUID())])
        XCTAssertThrowsError(try validator.validate(request, against: capabilities)) {
            XCTAssertEqual($0 as? VirtualTryOnError, .unsupportedCapability(.tooManyPersonImages))
        }

        capabilities = makeCapabilities(maxPersonImages: 3)
        let badMedia = makeRequest(personImages: [makeImage(mediaType: "image/gif")])
        XCTAssertThrowsError(try validator.validate(badMedia, against: capabilities)) {
            XCTAssertEqual($0 as? VirtualTryOnError, .unsupportedCapability(.unsupportedPersonMediaType))
        }
    }

    func testValidatorRejectsMissingInputsAndDuplicateStableIDs() {
        let validator = VirtualTryOnRequestValidator()
        let noPerson = makeRequest(personImages: [])
        XCTAssertThrowsError(try validator.validate(noPerson, against: makeCapabilities())) {
            XCTAssertEqual($0 as? VirtualTryOnError, .invalidInput(.noPersonImages))
        }

        let noGarment = makeRequest(garments: [])
        XCTAssertThrowsError(try validator.validate(noGarment, against: makeCapabilities())) {
            XCTAssertEqual($0 as? VirtualTryOnError, .invalidInput(.noGarments))
        }

        let duplicateID = UUID()
        let duplicateGarments = makeRequest(garments: [
            makeGarment(id: duplicateID, slot: .upperBody),
            makeGarment(id: duplicateID, slot: .outerwear)
        ])
        XCTAssertThrowsError(try validator.validate(duplicateGarments, against: makeCapabilities())) {
            XCTAssertEqual($0 as? VirtualTryOnError, .invalidInput(.duplicateGarmentID))
        }
    }

    func testValidatorRejectsMalformedProviderCapabilities() {
        let invalid = VirtualTryOnCapabilities(
            maxPersonImages: 0,
            supportedPersonMediaTypes: [],
            supportedGarmentMediaTypes: [],
            maxImageBytes: 0,
            maxImagePixelCount: 0,
            supportedSlots: [],
            maxGarmentsBySlot: [:],
            maxTotalGarments: 0,
            supportedQualities: [],
            supportedAspectRatios: [],
            supportsSeed: false,
            supportsCancellation: false,
            allowedProviderParameterKeys: [],
            maxPromptLength: 0
        )

        XCTAssertThrowsError(try VirtualTryOnRequestValidator().validate(makeRequest(), against: invalid)) {
            XCTAssertEqual($0 as? VirtualTryOnError, .configurationUnavailable)
        }
    }

    func testValidatorRejectsImageByteAndPixelLimits() {
        let validator = VirtualTryOnRequestValidator()
        let capabilities = makeCapabilities(maxImageBytes: 2, maxImagePixelCount: 100)
        let tooManyBytes = makeRequest(personImages: [makeImage(data: Data([1, 2, 3]))])
        XCTAssertThrowsError(try validator.validate(tooManyBytes, against: capabilities)) {
            XCTAssertEqual($0 as? VirtualTryOnError, .unsupportedCapability(.imageTooLarge))
        }

        let tooManyPixels = makeRequest(personImages: [makeImage(data: Data([1]), width: 11, height: 10)])
        XCTAssertThrowsError(try validator.validate(tooManyPixels, against: capabilities)) {
            XCTAssertEqual($0 as? VirtualTryOnError, .unsupportedCapability(.imagePixelCountTooLarge))
        }
    }

    func testValidatorRejectsUnsupportedAndOverfilledSlots() {
        let validator = VirtualTryOnRequestValidator()
        let footwear = makeGarment(id: UUID(), slot: .footwear)
        let unsupported = makeRequest(garments: [footwear])
        XCTAssertThrowsError(try validator.validate(unsupported, against: makeCapabilities(supportedSlots: [.upperBody]))) {
            XCTAssertEqual($0 as? VirtualTryOnError, .unsupportedCapability(.unsupportedSlot))
        }

        let overfilled = makeRequest(garments: [makeGarment(id: UUID()), makeGarment(id: UUID())])
        XCTAssertThrowsError(try validator.validate(overfilled, against: makeCapabilities())) {
            XCTAssertEqual($0 as? VirtualTryOnError, .unsupportedCapability(.slotLimitExceeded))
        }
    }

    func testValidatorRejectsUnsupportedOptionsAndUnknownParameters() {
        let validator = VirtualTryOnRequestValidator()
        let unsupportedVersion = makeRequest(options: TryOnOptions(schemaVersion: 99))
        XCTAssertThrowsError(try validator.validate(unsupportedVersion, against: makeCapabilities())) {
            XCTAssertEqual($0 as? VirtualTryOnError, .invalidInput(.unsupportedOptionsVersion))
        }

        let unknownParameter = makeRequest(options: TryOnOptions(providerParameters: ["secret_key": .string("never")]))
        XCTAssertThrowsError(try validator.validate(unknownParameter, against: makeCapabilities())) {
            XCTAssertEqual($0 as? VirtualTryOnError, .unsupportedCapability(.unsupportedProviderParameter))
        }
    }

    func testRegistrySelectsAndSortsProviders() async throws {
        let provider = MockVirtualTryOnProvider()
        let registry = try ProviderRegistry(providers: [provider])

        let selected = try await registry.provider(id: MockVirtualTryOnProvider.providerID)
        let descriptorIDs = await registry.descriptors().map(\.id)
        XCTAssertEqual(selected.descriptor.id, MockVirtualTryOnProvider.providerID)
        XCTAssertEqual(descriptorIDs, [MockVirtualTryOnProvider.providerID])
    }

    func testRegistryRejectsMissingDuplicateAndInvalidIDs() async throws {
        let provider = MockVirtualTryOnProvider()
        XCTAssertThrowsError(try ProviderRegistry(providers: [provider, provider])) {
            XCTAssertEqual($0 as? ProviderRegistryError, .duplicateProviderID(MockVirtualTryOnProvider.providerID))
        }

        let registry = try ProviderRegistry(providers: [provider])
        let missing = ProviderID(rawValue: "missing")
        do {
            _ = try await registry.provider(id: missing)
            XCTFail("Missing provider unexpectedly resolved")
        } catch let error as ProviderRegistryError {
            XCTAssertEqual(error, .providerNotFound(missing))
        }

        XCTAssertThrowsError(try ProviderID(validating: "Invalid ID")) {
            XCTAssertEqual($0 as? ProviderRegistryError, .invalidProviderID)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ProviderID.self, from: Data(#""Invalid ID""#.utf8)))
    }

    private func makeRequest(
        personImages: [ProviderImage]? = nil,
        garments: [TryOnGarment]? = nil,
        options: TryOnOptions = TryOnOptions()
    ) -> VirtualTryOnRequest {
        let garment = makeGarment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!)
        return VirtualTryOnRequest(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000600")!,
            personImages: personImages ?? [makeImage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!)],
            garments: garments ?? [garment],
            prompt: "Provider-neutral virtual try-on",
            promptVersion: TryOnPromptBuilder.version,
            options: options
        )
    }

    private func makeGarment(id: UUID, slot: TryOnSlot = .upperBody) -> TryOnGarment {
        TryOnGarment(
            clothingItemID: id,
            slot: slot,
            image: makeImage(id: UUID()),
            displayName: "Test garment"
        )
    }

    private func makeImage(
        id: UUID = UUID(),
        data: Data = Data([1]),
        mediaType: String = "image/png",
        width: Int = 10,
        height: Int = 10
    ) -> ProviderImage {
        ProviderImage(id: id, data: data, mediaType: mediaType, pixelWidth: width, pixelHeight: height)
    }

    private func makeCapabilities(
        maxPersonImages: Int = 3,
        maxImageBytes: Int = 1_024,
        maxImagePixelCount: Int = 10_000,
        supportedSlots: Set<TryOnSlot> = Set(TryOnSlot.allCases)
    ) -> VirtualTryOnCapabilities {
        let limits: [TryOnSlot: Int] = Dictionary(uniqueKeysWithValues: supportedSlots.map { slot in
            (slot, slot == .accessories ? 3 : 1)
        })
        return VirtualTryOnCapabilities(
            maxPersonImages: maxPersonImages,
            supportedPersonMediaTypes: ["image/png", "image/jpeg"],
            supportedGarmentMediaTypes: ["image/png", "image/jpeg"],
            maxImageBytes: maxImageBytes,
            maxImagePixelCount: maxImagePixelCount,
            supportedSlots: supportedSlots,
            maxGarmentsBySlot: limits,
            maxTotalGarments: 7,
            supportedQualities: [.standard, .high],
            supportedAspectRatios: Set(TryOnAspectRatio.allCases),
            supportsSeed: true,
            supportsCancellation: true,
            allowedProviderParameterKeys: ["fixture_variant"],
            maxPromptLength: 1_000
        )
    }
}

private enum ProviderContractAssertions {
    static func assertValidProvider(
        _ provider: any VirtualTryOnProvider,
        request: VirtualTryOnRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await provider.validateConfiguration()
        try VirtualTryOnRequestValidator().validate(request, against: provider.capabilities)
        let result = try await provider.generate(request: request)
        XCTAssertFalse(result.imageData.isEmpty, file: file, line: line)
        XCTAssertFalse(result.mediaType.isEmpty, file: file, line: line)
        XCTAssertFalse(provider.descriptor.id.rawValue.isEmpty, file: file, line: line)
        XCTAssertFalse(provider.descriptor.displayName.isEmpty, file: file, line: line)
    }
}

private func XCTAssertThrowsVirtualTryOnError(
    _ expected: VirtualTryOnError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as VirtualTryOnError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
