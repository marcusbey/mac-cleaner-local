import XCTest
@testable import CleanerCore
final class VendorGroupingTests: XCTestCase {
    func app(_ id: String, _ name: String, _ bytes: Int64 = 10) -> AppRecord {
        let url = URL(fileURLWithPath: "/Applications/\(name).app")
        return AppRecord(id:url.path,name:name,bundleID:id,url:url,version:"1",modified:nil,bytes:bytes)
    }
    func testGroupsVendorAndSumsUniqueApplications() {
        let a = app("com.adobe.a", "Alpha", 20), b = app("com.adobe.b", "Beta", 30)
        let result = VendorGrouping.groups(for:[a,b,a])
        XCTAssertEqual(result.count,1); XCTAssertEqual(result[0].name,"Adobe")
        XCTAssertEqual(result[0].apps.count,2); XCTAssertEqual(result[0].bytes,50)
    }
    func testMemberSearchPreservesGroupMembershipAndTotal() {
        let result = VendorGrouping.groups(for:[app("com.adobe.a","Alpha"),app("com.adobe.b","Beta")],query:"Beta")
        XCTAssertEqual(result.first?.apps.count,2)
        XCTAssertTrue(VendorGrouping.groups(for:[app("com.adobe.a","Alpha")],query:"absent").isEmpty)
    }
    func testGenericNamespacesAndMissingIDsRemainSeparate() {
        XCTAssertEqual(VendorGrouping.groups(for:[app("io.github.alpha","Alpha"),app("io.github.beta","Beta"),app("","No ID")]).count,3)
    }
    func testUngroupedAndLargestOrdering() {
        let apps = [app("com.adobe.a","Alpha",10),app("com.adobe.b","Beta",20),app("com.other.c","Other",50)]
        XCTAssertEqual(VendorGrouping.groups(for:apps,largestFirst:true).first?.name,"Other")
        XCTAssertEqual(VendorGrouping.groups(for:apps,enabled:false).count,3)
    }
}

extension VendorGroupingTests {
    func testSizeSectionsKeepSmallChildrenInsideLargeGroup() {
        let apps = [app("com.adobe.big","Big",2_000_000_000),app("com.adobe.small","Small",19_000_000),app("org.other.tiny","Tiny",100)]
        let groups = VendorGrouping.groups(for:apps,largestFirst:true)
        let sections = ApplicationHierarchy.sections(groups:groups,bySize:true)
        XCTAssertEqual(sections.map(\.id),["large","tiny"])
        XCTAssertEqual(sections[0].groups[0].apps.map(\.name),["Big","Small"])
        XCTAssertEqual(sections[0].groups[0].bytes,2_019_000_000)
    }
    func testSizeBucketBoundariesAndRelatedStorage() {
        let apps = [app("a.b.a","GB",1_000_000_000),app("a.c.a","Hundred",100_000_000),app("a.d.a","Ten",10_000_000)]
        let sections = ApplicationHierarchy.sections(groups:VendorGrouping.groups(for:apps,largestFirst:true),bySize:true)
        XCTAssertEqual(sections.map(\.id),["large","medium","small"])
        let a = apps[0]
        let withData = AppRecord(id:a.id,name:a.name,bundleID:a.bundleID,url:a.url,version:a.version,modified:a.modified,bytes:10,relatedBytes:2_000_000_000)
        XCTAssertEqual(VendorGrouping.groups(for:[withData]).first?.bytes,2_000_000_010)
    }
}
