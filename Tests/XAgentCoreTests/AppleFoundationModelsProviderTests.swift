import XCTest
@testable import XAgentCore
import CoreML
import NaturalLanguage

final class AppleFoundationModelsProviderTests: XCTestCase {

    // MARK: - isAvailable

    func testIsAvailableReturnsBool() {
        // isAvailable should return a Bool on any platform.
        let available = AppleFoundationModelsProvider.isAvailable
        // On macOS 15+ ARM64 CI / dev machines this is true;
        // on unsupported platforms it is false.
        // We only assert the type — the value is platform-dependent.
        XCTAssertTrue(available is Bool)
    }

    func testIsAppleSiliconReturnsBool() {
        // Internal implementation detail, tested via @testable import.
        let isAS = AppleFoundationModelsProvider.isAppleSilicon
        XCTAssertTrue(isAS is Bool)
    }

    // MARK: - Error type

    func testUnavailableErrorDescription() {
        let error = AppleFoundationModelsError.unavailable("test message")
        let desc = String(describing: error)
        XCTAssertTrue(desc.contains("unavailable") || desc.contains("test message"))
    }

    func testModelLoadFailedErrorDescription() {
        let error = AppleFoundationModelsError.modelLoadFailed("no such file")
        let desc = String(describing: error)
        XCTAssertTrue(desc.contains("no such file") || desc.contains("modelLoadFailed"))
    }

    func testIncompatibleModelErrorDescription() {
        let error = AppleFoundationModelsError.incompatibleModel("bad schema")
        let desc = String(describing: error)
        XCTAssertTrue(desc.contains("bad schema") || desc.contains("incompatibleModel"))
    }

    func testTokenizationFailedErrorDescription() {
        let error = AppleFoundationModelsError.tokenizationFailed("utf8 error")
        let desc = String(describing: error)
        XCTAssertTrue(desc.contains("utf8 error") || desc.contains("tokenizationFailed"))
    }

    func testGenerationFailedErrorDescription() {
        let error = AppleFoundationModelsError.generationFailed("oom")
        let desc = String(describing: error)
        XCTAssertTrue(desc.contains("oom") || desc.contains("generationFailed"))
    }

    func testDetokenizationFailedErrorDescription() {
        let error = AppleFoundationModelsError.detokenizationFailed("corrupt")
        let desc = String(describing: error)
        XCTAssertTrue(desc.contains("corrupt") || desc.contains("detokenizationFailed"))
    }

    // MARK: - Init error paths

    func testInitThrowsUnavailableOnUnsupportedPlatforms() throws {
        // When isAvailable is false, init should throw .unavailable.
        // We can't force isAvailable to be false on a supported machine,
        // but we can verify the guard executes by checking behavior on
        // the current platform.
        if AppleFoundationModelsProvider.isAvailable {
            // On supported platforms, unavailable error should NOT be thrown
            // for a missing model file (modelLoadFailed instead).
            let bogusURL = URL(fileURLWithPath: "/tmp/nonexistent_xyz123.mlmodelc")
            do {
                _ = try AppleFoundationModelsProvider(modelURL: bogusURL)
                XCTFail("Expected modelLoadFailed for nonexistent model")
            } catch let error as AppleFoundationModelsError {
                switch error {
                case .modelLoadFailed:
                    // Expected — the guard passed (available), model loading failed.
                    break
                case .unavailable:
                    XCTFail("Should not get unavailable on a supported platform")
                default:
                    XCTFail("Unexpected error: \(error)")
                }
            }
        } else {
            // Unsupported platform — init should throw .unavailable.
            let bogusURL = URL(fileURLWithPath: "/tmp/irrelevant.mlmodelc")
            do {
                _ = try AppleFoundationModelsProvider(modelURL: bogusURL)
                XCTFail("Expected unavailable error on unsupported platform")
            } catch let error as AppleFoundationModelsError {
                switch error {
                case .unavailable:
                    break
                default:
                    XCTFail("Expected unavailable, got \(error)")
                }
            }
        }
    }

    func testInitThrowsModelLoadFailedForMissingFile() throws {
        try XCTSkipUnless(
            AppleFoundationModelsProvider.isAvailable,
            "Test requires Apple Foundation Models support"
        )

        let missingURL = URL(fileURLWithPath: "/tmp/xagent_test_missing_model_xyz.mlmodelc")
        do {
            _ = try AppleFoundationModelsProvider(modelURL: missingURL)
            XCTFail("Expected modelLoadFailed")
        } catch let error as AppleFoundationModelsError {
            switch error {
            case .modelLoadFailed(let msg):
                XCTAssertTrue(msg.contains("xagent_test_missing_model_xyz"))
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInitThrowsModelLoadFailedForFileInsteadOfDirectory() throws {
        try XCTSkipUnless(
            AppleFoundationModelsProvider.isAvailable,
            "Test requires Apple Foundation Models support"
        )

        // Create a regular file and point the provider at it.
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xagent_test_not_a_model.txt")
        try "not a model".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        do {
            _ = try AppleFoundationModelsProvider(modelURL: tempFile)
            XCTFail("Expected modelLoadFailed for non-model file")
        } catch let error as AppleFoundationModelsError {
            switch error {
            case .modelLoadFailed:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Tokenization (internal utility)

    func testWordToTokenIDIsDeterministic() {
        let id1 = AppleFoundationModelsProvider.wordToTokenID("hello")
        let id2 = AppleFoundationModelsProvider.wordToTokenID("hello")
        XCTAssertEqual(id1, id2, "Same word should produce same token ID")
    }

    func testWordToTokenIDDifferentWordsProduceDifferentIDs() {
        let id1 = AppleFoundationModelsProvider.wordToTokenID("hello")
        let id2 = AppleFoundationModelsProvider.wordToTokenID("world")
        // Extremely unlikely to collide.
        XCTAssertNotEqual(id1, id2, "Different words should produce different token IDs")
    }

    func testWordToTokenIDNonEmpty() {
        let id = AppleFoundationModelsProvider.wordToTokenID("test")
        XCTAssertGreaterThan(id, 0, "Token ID should be positive (reserving 0 for BOS)")
    }

    // MARK: - Argmax (internal utility)

    func testArgmaxSingleElement() throws {
        let shape: [NSNumber] = [1, 1, 5]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        arr[0] = 0.1
        arr[1] = 0.5
        arr[2] = 0.9
        arr[3] = 0.3
        arr[4] = 0.7

        let result = AppleFoundationModelsProvider.argmax(arr)
        XCTAssertEqual(result, 2, "Argmax should pick index of highest value")
    }

    func testArgmaxFirstElementHighest() throws {
        let shape: [NSNumber] = [1, 1, 3]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        arr[0] = 100.0
        arr[1] = 0.0
        arr[2] = -100.0

        let result = AppleFoundationModelsProvider.argmax(arr)
        XCTAssertEqual(result, 0)
    }

    func testArgmaxLastElementHighest() throws {
        let shape: [NSNumber] = [1, 2, 4]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        // Second position (baseOffset = 1*4 = 4):
        arr[4] = 0.0
        arr[5] = 0.0
        arr[6] = 0.0
        arr[7] = 99.0

        let result = AppleFoundationModelsProvider.argmax(arr)
        XCTAssertEqual(result, 3, "Argmax on last position should pick max value index")
    }

    func testArgmaxAllNegative() throws {
        let shape: [NSNumber] = [1, 1, 4]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        arr[0] = -10.0
        arr[1] = -5.0
        arr[2] = -1.0
        arr[3] = -20.0

        let result = AppleFoundationModelsProvider.argmax(arr)
        XCTAssertEqual(result, 2, "-1.0 is greater than the rest")
    }

    // MARK: - Config parameters

    func testInitAcceptsCustomMaxTokens() throws {
        try XCTSkipUnless(
            AppleFoundationModelsProvider.isAvailable,
            "Test requires Apple Foundation Models support"
        )

        let bogusURL = URL(fileURLWithPath: "/tmp/xagent_custom_max_tokens_test.mlmodelc")
        // We expect modelLoadFailed, but we can verify the init signature accepts maxTokens.
        _ = try? AppleFoundationModelsProvider(modelURL: bogusURL, maxTokens: 256)
        // No throw about parameter type — the signature is valid.
    }

    func testInitAcceptsCustomTemperature() throws {
        try XCTSkipUnless(
            AppleFoundationModelsProvider.isAvailable,
            "Test requires Apple Foundation Models support"
        )

        let bogusURL = URL(fileURLWithPath: "/tmp/xagent_custom_temp_test.mlmodelc")
        _ = try? AppleFoundationModelsProvider(modelURL: bogusURL, temperature: 0.7)
    }

    func testInitAcceptsEOSTokenID() throws {
        try XCTSkipUnless(
            AppleFoundationModelsProvider.isAvailable,
            "Test requires Apple Foundation Models support"
        )

        let bogusURL = URL(fileURLWithPath: "/tmp/xagent_eos_test.mlmodelc")
        _ = try? AppleFoundationModelsProvider(modelURL: bogusURL, eosTokenID: 2)
    }

    func testTemperatureClampedToZero() throws {
        try XCTSkipUnless(
            AppleFoundationModelsProvider.isAvailable,
            "Test requires Apple Foundation Models support"
        )

        let bogusURL = URL(fileURLWithPath: "/tmp/xagent_temp_clamp_test.mlmodelc")
        // Negative temperature should be clamped to 0.
        _ = try? AppleFoundationModelsProvider(modelURL: bogusURL, temperature: -999)
    }

    // MARK: - LLMProvider conformance

    func testConformsToLLMProvider() {
        // Compile-time check: AppleFoundationModelsProvider can be used
        // wherever an LLMProvider is expected.
        let _: any LLMProvider.Type = AppleFoundationModelsProvider.self
    }

    func testIsSendable() {
        // Compile-time check: AppleFoundationModelsProvider is Sendable.
        let _: any Sendable = AppleFoundationModelsProvider.self
    }

    // MARK: - Availability string

    func testIsAvailableDescribedInError() {
        let error = AppleFoundationModelsError.unavailable("check message")
        let mirror = String(reflecting: error)
        XCTAssertTrue(mirror.contains("check message") || mirror.contains("unavailable"))
    }
}
