import Darwin
import FluidAudio
import XCTest
@testable import Yap

final class ModelNetworkPolicyTests: XCTestCase {
    func testModelDownloadsIgnoreAmbientTokensAndRegistryOverrides() {
        let removedKeys = [
            "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_HUB_TOKEN",
            "HF_TOKEN_PATH", "HF_ENDPOINT", "HF_INFERENCE_ENDPOINT",
            "HUGGINGFACE_HUB_BASE_URL", "HF_HUB_BASE_URL",
            "REGISTRY_URL", "MODEL_REGISTRY_URL",
        ]
        let enforcedKeys = [
            "HF_HUB_DISABLE_IMPLICIT_TOKEN",
            "HF_HUB_DISABLE_TELEMETRY",
            "HF_HUB_DISABLE_UPDATE_CHECK",
            "DO_NOT_TRACK",
        ]
        let keys = removedKeys + enforcedKeys
        let previous = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil {
                    _ = setenv(key, value, 1)
                } else {
                    _ = unsetenv(key)
                }
            }
        }

        for key in removedKeys {
            _ = setenv(key, "https://attacker.invalid", 1)
        }
        _ = setenv("HF_TOKEN", "test-only-secret", 1)
        _ = setenv("HF_HUB_DISABLE_IMPLICIT_TOKEN", "0", 1)
        _ = setenv("HF_HUB_DISABLE_TELEMETRY", "0", 1)
        _ = setenv("HF_HUB_DISABLE_UPDATE_CHECK", "0", 1)
        _ = setenv("DO_NOT_TRACK", "0", 1)

        ModelNetworkPolicy.apply()

        for key in removedKeys {
            XCTAssertNil(ProcessInfo.processInfo.environment[key], "\(key) must not be inherited")
        }
        for key in enforcedKeys {
            XCTAssertEqual(ProcessInfo.processInfo.environment[key], "1")
        }
        XCTAssertEqual(ModelRegistry.baseURL, "https://huggingface.co")
    }
}
