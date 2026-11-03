import Darwin
import FluidAudio

/// Lock model downloads to the public Hugging Face origin and prevent ambient
/// shell credentials or endpoint overrides from being inherited by the app or
/// its Python sidecar. Yap uses public models; it has no reason to read a user's
/// personal Hugging Face access token.
enum ModelNetworkPolicy {
    private static let untrustedOverrides = [
        "HF_TOKEN",
        "HUGGING_FACE_HUB_TOKEN",
        "HUGGINGFACE_HUB_TOKEN",
        "HF_TOKEN_PATH",
        "HF_ENDPOINT",
        "HF_INFERENCE_ENDPOINT",
        "HUGGINGFACE_HUB_BASE_URL",
        "HF_HUB_BASE_URL",
        "REGISTRY_URL",
        "MODEL_REGISTRY_URL",
    ]

    static func apply() {
        // These values are inherited by Process children too, so this protects
        // both FluidAudio's Swift downloads and Pocket's Python hub client.
        for key in untrustedOverrides {
            _ = unsetenv(key)
        }

        // Public model downloads do not need credentials. Avoid implicit use
        // of tokens saved by a different app and disable Hugging Face telemetry.
        _ = setenv("HF_HUB_DISABLE_IMPLICIT_TOKEN", "1", 1)
        _ = setenv("HF_HUB_DISABLE_TELEMETRY", "1", 1)
        _ = setenv("HF_HUB_DISABLE_UPDATE_CHECK", "1", 1)
        _ = setenv("DO_NOT_TRACK", "1", 1)

        // FluidAudio also accepts REGISTRY_URL / MODEL_REGISTRY_URL overrides.
        // Set its API explicitly rather than relying on inherited environment.
        ModelRegistry.baseURL = "https://huggingface.co"
    }
}
