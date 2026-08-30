//
//  UpdatePolicyTests.swift
//  TecolotTests
//

import Testing
@testable import Tecolot

struct UpdatePolicyTests {
    @Test func permitsReleaseBundle() {
        #expect(UpdatePolicy.permitsUpdates(
            bundleIdentifier: "com.tirania.Tecolot",
            bundleNames: ["Tecolot"]
        ))
    }

    @Test func rejectsDebugBundleIdentifier() {
        #expect(!UpdatePolicy.permitsUpdates(
            bundleIdentifier: "com.tirania.Tecolot.debug",
            bundleNames: ["Tecolot"]
        ))
    }

    @Test func rejectsDebugBundleName() {
        #expect(!UpdatePolicy.permitsUpdates(
            bundleIdentifier: "com.tirania.Tecolot",
            bundleNames: ["Tecolot Debug"]
        ))
    }
}
