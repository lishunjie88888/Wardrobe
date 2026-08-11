import XCTest
@testable import Wardrobe

@MainActor
final class Stage7TryOnWorkspaceTests: XCTestCase {
    func testClothingCategoryMappingCoversFiveSlotsAndUnsupportedValues() {
        let mapper = ClothingToTryOnSlotMapper()
        XCTAssertEqual(mapper.slot(for: ClothingCategory.tops.rawValue), .supported(.upperBody))
        XCTAssertEqual(mapper.slot(for: ClothingCategory.outerwear.rawValue), .supported(.outerwear))
        XCTAssertEqual(mapper.slot(for: ClothingCategory.bottoms.rawValue), .supported(.lowerBody))
        XCTAssertEqual(mapper.slot(for: ClothingCategory.footwear.rawValue), .supported(.footwear))
        XCTAssertEqual(mapper.slot(for: ClothingCategory.accessories.rawValue), .supported(.accessories))
        XCTAssertEqual(mapper.slot(for: ClothingCategory.dresses.rawValue), .unsupported)
        XCTAssertEqual(mapper.slot(for: "future-category"), .unsupported)
    }

    func testSessionAddsReplacesRemovesAndClearsWithoutTouchingPerson() {
        let personID = UUID(), first = UUID(), replacement = UUID(), pants = UUID()
        var session = TryOnSession(personProfileID: personID, selectedPersonImageIDs: [UUID()])
        session.add(clothingID: first, to: .upperBody)
        session.add(clothingID: replacement, to: .upperBody)
        session.add(clothingID: pants, to: .lowerBody)
        XCTAssertEqual(session.garmentIDs(in: .upperBody), [replacement])
        session.remove(clothingID: replacement, from: .upperBody)
        XCTAssertTrue(session.garmentIDs(in: .upperBody).isEmpty)
        session.clearGarments()
        XCTAssertEqual(session.personProfileID, personID)
        XCTAssertEqual(session.garmentCount, 0)
    }

    func testAccessoriesSupportMultipleValuesAndStableReordering() {
        let first = UUID(), second = UUID(), third = UUID()
        var session = TryOnSession()
        session.add(clothingID: first, to: .accessories)
        session.add(clothingID: second, to: .accessories)
        session.add(clothingID: third, to: .accessories)
        session.add(clothingID: first, to: .accessories)
        session.moveAccessory(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(session.garmentIDs(in: .accessories), [third, first, second])
    }

    func testSessionReconcileDropsStaleClothingOnly() {
        let live = UUID(), stale = UUID()
        var session = TryOnSession(personProfileID: UUID(), selectedPersonImageIDs: [UUID()])
        session.add(clothingID: live, to: .upperBody)
        session.add(clothingID: stale, to: .lowerBody)
        session.reconcile(activeClothingIDs: [live])
        XCTAssertEqual(session.garmentIDs(in: .upperBody), [live])
        XCTAssertTrue(session.garmentIDs(in: .lowerBody).isEmpty)
        XCTAssertNotNil(session.personProfileID)
    }

    func testPersonReferenceResolutionSupportsDefaultAndExplicitProfile() throws {
        let fixture = try makeFixture()
        let other = try fixture.addPerson(name: "另一个人物", isDefault: false, imageCount: 2)
        let defaultSet = try fixture.personService.defaultReferenceSet()
        let explicitSet = try fixture.personService.referenceSet(profileID: other.id)
        XCTAssertEqual(defaultSet?.profileID, fixture.profile.id)
        XCTAssertEqual(defaultSet?.primaryImage?.id, fixture.primaryImage.id)
        XCTAssertEqual(explicitSet?.profileID, other.id)
        XCTAssertEqual(explicitSet?.additionalImages.count, 1)
    }

    func testRequestBuilderUsesProcessedResourcesAndCorrectSlots() async throws {
        let fixture = try makeFixture()
        let loader = RecordingTryOnLoader(data: Self.pngData)
        let builder = VirtualTryOnRequestBuilder(loader: loader)
        var session = TryOnSession(personProfileID: fixture.profile.id, selectedPersonImageIDs: [fixture.primaryImage.id])
        session.add(clothingID: fixture.top.id, to: .upperBody)
        session.add(clothingID: fixture.shoes.id, to: .footwear)
        let references = try XCTUnwrap(fixture.personService.defaultReferenceSet())
        let request = try await builder.build(session: session, person: references, clothing: fixture.clothing, capabilities: MockVirtualTryOnProvider().capabilities)
        XCTAssertEqual(request.personImages.count, 1)
        XCTAssertEqual(Set(request.garments.map(\.slot)), [.upperBody, .footwear])
        XCTAssertEqual(request.promptVersion, TryOnPromptBuilder.version)
        let requested = await loader.requestedResources()
        XCTAssertTrue(requested.contains(fixture.primaryImage.processedResourceID!))
        XCTAssertTrue(requested.contains(fixture.top.processedResourceID!))
        XCTAssertFalse(requested.contains(fixture.top.originalResourceID))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains("/Users/"))
    }

    func testRequestBuilderFallsBackToOriginalGarmentResource() async throws {
        let fixture = try makeFixture(topHasProcessed: false)
        let loader = RecordingTryOnLoader(data: Self.pngData)
        let builder = VirtualTryOnRequestBuilder(loader: loader)
        var session = TryOnSession(personProfileID: fixture.profile.id, selectedPersonImageIDs: [fixture.primaryImage.id])
        session.add(clothingID: fixture.top.id, to: .upperBody)
        _ = try await builder.build(session: session, person: try XCTUnwrap(fixture.personService.defaultReferenceSet()), clothing: fixture.clothing, capabilities: MockVirtualTryOnProvider().capabilities)
        let requested = await loader.requestedResources()
        XCTAssertTrue(requested.contains(fixture.top.originalResourceID))
    }

    func testRequestBuilderRejectsMissingPersonReferenceAndGarment() async throws {
        let fixture = try makeFixture()
        let builder = VirtualTryOnRequestBuilder(loader: RecordingTryOnLoader(data: Self.pngData))
        let references = try XCTUnwrap(fixture.personService.defaultReferenceSet())
        var noReference = TryOnSession(personProfileID: fixture.profile.id)
        noReference.add(clothingID: fixture.top.id, to: .upperBody)
        await XCTAssertThrowsWorkspaceError(.personHasNoReference) {
            try await builder.build(session: noReference, person: references, clothing: fixture.clothing, capabilities: MockVirtualTryOnProvider().capabilities)
        }
        let noGarment = TryOnSession(personProfileID: fixture.profile.id, selectedPersonImageIDs: [fixture.primaryImage.id])
        await XCTAssertThrowsWorkspaceError(.noGarments) {
            try await builder.build(session: noGarment, person: references, clothing: fixture.clothing, capabilities: MockVirtualTryOnProvider().capabilities)
        }
    }

    func testRequestBuilderRejectsUnavailableAndInvalidResources() async throws {
        let fixture = try makeFixture()
        let references = try XCTUnwrap(fixture.personService.defaultReferenceSet())
        var session = TryOnSession(personProfileID: fixture.profile.id, selectedPersonImageIDs: [fixture.primaryImage.id])
        session.add(clothingID: UUID(), to: .upperBody)
        await XCTAssertThrowsWorkspaceErrorMatching {
            try await VirtualTryOnRequestBuilder(loader: RecordingTryOnLoader(data: Self.pngData)).build(session: session, person: references, clothing: fixture.clothing, capabilities: MockVirtualTryOnProvider().capabilities)
        } check: {
            if case .clothingUnavailable = $0 { true } else { false }
        }

        session = TryOnSession(personProfileID: fixture.profile.id, selectedPersonImageIDs: [fixture.primaryImage.id])
        session.add(clothingID: fixture.top.id, to: .upperBody)
        await XCTAssertThrowsWorkspaceError(.invalidImageResource) {
            try await VirtualTryOnRequestBuilder(loader: RecordingTryOnLoader(data: Data("bad".utf8))).build(session: session, person: references, clothing: fixture.clothing, capabilities: MockVirtualTryOnProvider().capabilities)
        }
    }

    func testViewModelLoadsDefaultPersonAndPreservesGarmentsAcrossSwitch() throws {
        let fixture = try makeFixture()
        let other = try fixture.addPerson(name: "切换人物", isDefault: false, imageCount: 1)
        let model = fixture.makeViewModel()
        model.load()
        XCTAssertEqual(model.session.personProfileID, fixture.profile.id)
        XCTAssertTrue(model.addClothing(fixture.top.id))
        model.selectPerson(other.id)
        XCTAssertEqual(model.session.personProfileID, other.id)
        XCTAssertEqual(model.session.garmentIDs(in: .upperBody), [fixture.top.id])
        XCTAssertEqual(model.generationState, .idle)
    }

    func testViewModelShowsSafeStatesForNoPersonAndPersonWithoutImage() throws {
        let container = try WardrobeModelContainerFactory.inMemory()
        let repository = SwiftDataWardrobeRepository(container: container)
        let loader = RecordingTryOnLoader(data: Self.pngData)
        let model = TryOnViewModel(dependencies: TryOnFeatureDependencies(clothing: ClothingManagementService(repository: repository), person: PersonManagementService(repository: repository), imageLoader: loader, provider: MockVirtualTryOnProvider()))
        model.load()
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNil(model.session.personProfileID)

        let emptyProfile = PersonProfile(name: "无图片人物", isDefault: true)
        try repository.insert(emptyProfile); try repository.save(); try repository.setDefaultPersonProfile(id: emptyProfile.id, at: .now)
        model.load()
        XCTAssertEqual(model.session.personProfileID, emptyProfile.id)
        XCTAssertTrue(model.session.selectedPersonImageIDs.isEmpty)
        XCTAssertNil(model.currentReferences?.primaryImage)
    }

    func testViewModelRejectsIncompatibleAndUnsupportedDrops() throws {
        let fixture = try makeFixture(includeUnsupported: true)
        let model = fixture.makeViewModel()
        model.load()
        XCTAssertFalse(model.addClothing(fixture.top.id, to: .lowerBody))
        let unsupported = try XCTUnwrap(model.clothing.first { $0.draft.categoryCode == ClothingCategory.other.rawValue })
        XCTAssertFalse(model.addClothing(unsupported.id))
        XCTAssertEqual(model.session.garmentCount, 0)
    }

    func testBrowserFilteringDoesNotInvalidateSelectedGarment() throws {
        let fixture = try makeFixture()
        let model = fixture.makeViewModel()
        model.load(); XCTAssertTrue(model.addClothing(fixture.top.id))
        model.searchText = "没有匹配"
        model.filtersChanged()
        XCTAssertTrue(model.clothing.isEmpty)
        XCTAssertEqual(model.session.garmentIDs(in: .upperBody), [fixture.top.id])
        XCTAssertEqual(model.clothingRecord(id: fixture.top.id)?.draft.name, "上衣")
    }

    func testMockGenerationSuccessAndDuplicateSubmissionPrevention() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider(behavior: .success(delay: .milliseconds(80))))
        let model = fixture.makeViewModel()
        model.load(); XCTAssertTrue(model.addClothing(fixture.top.id)); model.generate(); model.generate()
        try await eventually { if case .success = model.generationState { true } else { false } }
        guard case let .success(preview) = model.generationState else { return XCTFail("Expected success") }
        XCTAssertEqual(preview.personName, "默认人物")
        XCTAssertEqual(preview.garmentsBySlot[.upperBody], ["上衣"])
    }

    func testMockFailureCanRetryCurrentSession() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider(behavior: .transientFailures(count: 1)))
        let model = fixture.makeViewModel()
        model.load(); XCTAssertTrue(model.addClothing(fixture.top.id)); model.generate()
        try await eventually { if case .failure = model.generationState { true } else { false } }
        XCTAssertEqual(model.session.garmentIDs(in: .upperBody), [fixture.top.id])
        model.retry()
        try await eventually { if case .success = model.generationState { true } else { false } }
    }

    func testMockCancellationHasDistinctState() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider(behavior: .success(delay: .seconds(2))))
        let model = fixture.makeViewModel()
        model.load(); XCTAssertTrue(model.addClothing(fixture.top.id)); model.generate()
        try await eventually { model.isGenerating }
        model.cancelGeneration()
        try await eventually { model.generationState == .cancelled }
    }

    func testPersonSwitchCancelsGenerationAndIgnoresLateResult() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider(behavior: .success(delay: .milliseconds(300))))
        let other = try fixture.addPerson(name: "新人物", isDefault: false, imageCount: 1)
        let model = fixture.makeViewModel()
        model.load(); XCTAssertTrue(model.addClothing(fixture.top.id)); model.generate()
        try await eventually { model.isGenerating }
        model.selectPerson(other.id)
        XCTAssertEqual(model.generationState, .idle)
        XCTAssertEqual(model.session.garmentIDs(in: .upperBody), [fixture.top.id])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.generationState, .idle)
    }

    func testReferenceSelectionEnforcesProviderLimitWithoutSilentlySelectingAll() throws {
        let fixture = try makeFixture(defaultImageCount: 5)
        let model = fixture.makeViewModel()
        model.load()
        XCTAssertEqual(model.session.selectedPersonImageIDs.count, 3)
        XCTAssertEqual(model.omittedReferenceCount, 2)
        let unselected = try XCTUnwrap(model.currentReferences?.additionalImages.last?.id)
        model.toggleReference(unselected)
        XCTAssertEqual(model.session.selectedPersonImageIDs.count, 3)
        XCTAssertNotNil(model.message)
    }

    private func makeFixture(
        topHasProcessed: Bool = true,
        includeUnsupported: Bool = false,
        defaultImageCount: Int = 1,
        provider: any VirtualTryOnProvider = MockVirtualTryOnProvider()
    ) throws -> Fixture {
        let container = try WardrobeModelContainerFactory.inMemory()
        let repository = SwiftDataWardrobeRepository(container: container)
        let profile = PersonProfile(name: "默认人物", isDefault: true)
        try repository.insert(profile)
        var images: [PersonImage] = []
        for index in 0..<defaultImageCount {
            let id = UUID()
            let original = try resource(owner: .person, id: id, kind: .original(fileExtension: "png"))
            let processed = try resource(owner: .person, id: id, kind: .processed)
            let image = PersonImage(id: id, profile: profile, isPrimary: index == 0, originalResourceID: original.rawValue, processedResourceID: processed.rawValue, pixelWidth: 1, pixelHeight: 1)
            try repository.insert(image); images.append(image)
        }
        let top = try addClothing(name: "上衣", category: .tops, repository: repository, hasProcessed: topHasProcessed)
        let shoes = try addClothing(name: "鞋", category: .footwear, repository: repository)
        if includeUnsupported { _ = try addClothing(name: "其他", category: .other, repository: repository) }
        try repository.save()
        try repository.setDefaultPersonProfile(id: profile.id, at: .now)
        return Fixture(repository: repository, personService: PersonManagementService(repository: repository), profile: profile, primaryImage: try XCTUnwrap(images.first).record, top: top, shoes: shoes, provider: provider, loader: RecordingTryOnLoader(data: Self.pngData))
    }

    private func addClothing(name: String, category: ClothingCategory, repository: SwiftDataWardrobeRepository, hasProcessed: Bool = true) throws -> ClothingRecord {
        let id = UUID()
        let original = try resource(owner: .garment, id: id, kind: .original(fileExtension: "png"))
        let processed = try resource(owner: .garment, id: id, kind: .processed)
        try repository.insert(ClothingItem(id: id, name: name, categoryCode: category.rawValue, originalResourceID: original.rawValue, processedResourceID: hasProcessed ? processed.rawValue : nil))
        return ClothingRecord(id: id, draft: ClothingDraft(name: name, categoryCode: category.rawValue), originalResourceID: original, processedResourceID: hasProcessed ? processed : nil, thumbnailResourceID: nil, archivedAt: nil, createdAt: .now, updatedAt: .now)
    }

    private func resource(owner: StorageOwnerKind, id: UUID, kind: StorageResourceKind) throws -> StorageResourceID {
        try StorageResourceID(owner: StorageOwner(kind: owner, id: id), kind: kind)
    }

    private func eventually(timeout: Duration = .seconds(2), condition: @escaping @MainActor () -> Bool) async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition was not met before timeout")
    }

    private static let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

@MainActor
private struct Fixture {
    let repository: SwiftDataWardrobeRepository
    let personService: PersonManagementService
    let profile: PersonProfile
    let primaryImage: PersonImageRecord
    let top: ClothingRecord
    let shoes: ClothingRecord
    let provider: any VirtualTryOnProvider
    let loader: RecordingTryOnLoader

    var clothing: [ClothingRecord] { (try? ClothingManagementService(repository: repository).clothing(matching: ClothingQuery())) ?? [] }

    @MainActor func addPerson(name: String, isDefault: Bool, imageCount: Int) throws -> PersonProfileRecord {
        let profile = PersonProfile(name: name, isDefault: isDefault)
        try repository.insert(profile)
        for index in 0..<imageCount {
            let id = UUID()
            let original = try StorageResourceID(owner: StorageOwner(kind: .person, id: id), kind: .original(fileExtension: "png"))
            let processed = try StorageResourceID(owner: StorageOwner(kind: .person, id: id), kind: .processed)
            let image = PersonImage(id: id, profile: profile, isPrimary: index == 0, originalResourceID: original.rawValue, processedResourceID: processed.rawValue, pixelWidth: 1, pixelHeight: 1)
            try repository.insert(image)
        }
        try repository.save()
        return try XCTUnwrap(PersonManagementService(repository: repository).profiles().first { $0.id == profile.id })
    }

    @MainActor func makeViewModel() -> TryOnViewModel {
        TryOnViewModel(dependencies: TryOnFeatureDependencies(clothing: ClothingManagementService(repository: repository), person: personService, imageLoader: loader, provider: provider))
    }
}

private extension PersonImage {
    var record: PersonImageRecord {
        PersonImageRecord(id: id, profileID: profile.id, isPrimary: isPrimary, originalResourceID: try! StorageResourceID(rawValue: originalResourceID), processedResourceID: try! processedResourceID.map(StorageResourceID.init(rawValue:)), thumbnailResourceID: nil, pixelWidth: pixelWidth, pixelHeight: pixelHeight, createdAt: createdAt, updatedAt: updatedAt)
    }
}

private actor RecordingTryOnLoader: TryOnResourceLoading {
    let data: Data
    private var resources: [StorageResourceID] = []
    init(data: Data) { self.data = data }
    func data(for resourceID: StorageResourceID) async throws -> Data { resources.append(resourceID); return data }
    func requestedResources() -> [StorageResourceID] { resources }
}

@MainActor
private func XCTAssertThrowsWorkspaceError<T>(
    _ expected: TryOnWorkspaceError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do { _ = try await operation(); XCTFail("Expected error", file: file, line: line) }
    catch let error as TryOnWorkspaceError { XCTAssertEqual(error, expected, file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

@MainActor
private func XCTAssertThrowsWorkspaceErrorMatching<T>(
    operation: () async throws -> T,
    check: (TryOnWorkspaceError) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do { _ = try await operation(); XCTFail("Expected error", file: file, line: line) }
    catch let error as TryOnWorkspaceError { XCTAssertTrue(check(error), file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
