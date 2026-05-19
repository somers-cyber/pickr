import XCTest
@testable import moviefinder

@MainActor
final class StreamingServicesTests: XCTestCase {

    private let key = "selected_streaming_services_v2"

    // Clear UserDefaults before and after every test to prevent state leakage.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - US service catalogue

    func testAllServicesHaveUniqueIds() async {
        let ids = StreamingService.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Every StreamingService must have a unique id")
    }

    func testRequiredUSServicesArePresent() async {
        let ids = Set(StreamingService.all.map(\.id))
        XCTAssertTrue(ids.contains(8),    "Netflix (id=8) must be in the US list")
        XCTAssertTrue(ids.contains(9),    "Prime Video (id=9) must be in the US list")
        XCTAssertTrue(ids.contains(337),  "Disney+ (id=337) must be in the US list")
        XCTAssertTrue(ids.contains(15),   "Hulu (id=15) must be in the US list")
        XCTAssertGreaterThanOrEqual(ids.count, 8, "At least 8 US services should be configured")
    }

    func testEveryServiceHasNonEmptyNameAndSymbol() async {
        for svc in StreamingService.all {
            XCTAssertFalse(svc.name.isEmpty,       "\(svc.id): name must not be empty")
            XCTAssertFalse(svc.logoSymbol.isEmpty, "\(svc.name): logoSymbol must not be empty")
        }
    }

    // MARK: - Single selection

    func testSingleSelection() async {
        let prefs   = StreamingPreferences()
        let netflix = StreamingService.all.first(where: { $0.id == 8 })!
        prefs.toggle(netflix)

        XCTAssertTrue(prefs.isSelected(netflix))
        XCTAssertEqual(prefs.selectedServiceIds.count, 1)
    }

    // MARK: - Multiple selection

    func testMultipleSelectionIsAdditive() async {
        let prefs  = StreamingPreferences()
        let svc1   = StreamingService.all.first(where: { $0.id == 8  })!  // Netflix
        let svc2   = StreamingService.all.first(where: { $0.id == 15 })!  // Hulu
        prefs.toggle(svc1)
        prefs.toggle(svc2)

        XCTAssertTrue(prefs.isSelected(svc1))
        XCTAssertTrue(prefs.isSelected(svc2))
        XCTAssertEqual(prefs.selectedServiceIds.count, 2)
    }

    // MARK: - Deselection

    func testDeselectionRemovesService() async {
        let prefs   = StreamingPreferences()
        let netflix = StreamingService.all.first(where: { $0.id == 8 })!
        prefs.toggle(netflix)  // select
        prefs.toggle(netflix)  // deselect

        XCTAssertFalse(prefs.isSelected(netflix))
        XCTAssertTrue(prefs.selectedServiceIds.isEmpty)
    }

    func testClearAllRemovesEverySelection() async {
        let prefs = StreamingPreferences()
        StreamingService.all.forEach { prefs.toggle($0) }
        XCTAssertFalse(prefs.selectedServiceIds.isEmpty)

        prefs.clearAll()
        XCTAssertTrue(prefs.selectedServiceIds.isEmpty)
    }

    // MARK: - Watch Now filter logic

    // No services selected → every movie passes (no filter active).
    func testNoSelectionPassesAllMovies() async {
        let prefs = StreamingPreferences()
        XCTAssertTrue(prefs.moviePassesServiceFilter(availableServiceIds: [8, 15]))
        XCTAssertTrue(prefs.moviePassesServiceFilter(availableServiceIds: [337]))
        XCTAssertTrue(prefs.moviePassesServiceFilter(availableServiceIds: []))
    }

    // Selecting Netflix filters out anything NOT on Netflix.
    func testSingleSelectionFiltersMovies() async {
        let prefs   = StreamingPreferences()
        let netflix = StreamingService.all.first(where: { $0.id == 8 })!
        prefs.toggle(netflix)

        XCTAssertTrue(prefs.moviePassesServiceFilter(availableServiceIds: [8]),      "Netflix movie → passes")
        XCTAssertTrue(prefs.moviePassesServiceFilter(availableServiceIds: [8, 15]),  "Netflix+Hulu movie → passes")
        XCTAssertFalse(prefs.moviePassesServiceFilter(availableServiceIds: [15]),    "Hulu-only → filtered out")
        XCTAssertFalse(prefs.moviePassesServiceFilter(availableServiceIds: []),      "Nowhere → filtered out")
    }

    // Selecting Netflix + Hulu passes any movie on either, blocks others.
    func testMultipleSelectionFiltersBothCorrectly() async {
        let prefs  = StreamingPreferences()
        let svc1   = StreamingService.all.first(where: { $0.id == 8  })!
        let svc2   = StreamingService.all.first(where: { $0.id == 15 })!
        prefs.toggle(svc1)
        prefs.toggle(svc2)

        XCTAssertTrue(prefs.moviePassesServiceFilter(availableServiceIds: [8]),       "Netflix only → passes")
        XCTAssertTrue(prefs.moviePassesServiceFilter(availableServiceIds: [15]),      "Hulu only → passes")
        XCTAssertTrue(prefs.moviePassesServiceFilter(availableServiceIds: [8, 15]),   "Both → passes")
        XCTAssertFalse(prefs.moviePassesServiceFilter(availableServiceIds: [337]),    "Disney+ only → filtered out")
        XCTAssertFalse(prefs.moviePassesServiceFilter(availableServiceIds: []),       "Nowhere → filtered out")
    }

    // MARK: - Persistence

    func testSelectionPersistedAcrossInstances() async {
        let prefs1  = StreamingPreferences()
        let netflix = StreamingService.all.first(where: { $0.id == 8 })!
        prefs1.toggle(netflix)

        // Fresh instance reads from UserDefaults — must see the same selection.
        let prefs2 = StreamingPreferences()
        XCTAssertTrue(prefs2.isSelected(netflix), "Selection must persist across StreamingPreferences instances")
    }

    func testLoadStripsStaleServiceIds() async {
        // Write an ID that doesn't correspond to any known service.
        UserDefaults.standard.set([8, 99999], forKey: key)
        let prefs = StreamingPreferences()

        XCTAssertTrue(prefs.selectedServiceIds.contains(8),      "Valid id=8 should be kept")
        XCTAssertFalse(prefs.selectedServiceIds.contains(99999), "Unknown id=99999 should be stripped on load")
    }
}
