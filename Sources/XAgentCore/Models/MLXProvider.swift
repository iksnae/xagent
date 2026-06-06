import Foundation

// MARK: - MLX Swift LLM provider
//
// An ``LLMProvider`` backed by Apple's MLX framework for local,
// on-device inference with open-weight models (Llama, Mistral,
// Phi, Gemma, etc.).  The entire implementation is conditional
// on `canImport(MLX)` so that non-MLX builds compile without
// requiring the mlx-swift package.

// MARK: - Errors

/// Errors thrown by ``MLXProvider``.
public enum MLXProviderError: Error, Sendable {
    /// MLX is not linked in this build configuration.
    case unavailable
    /// The model could not be loaded from the given identifier or path.
    case modelLoadFailed(String)
    /// Generation failed with an underlying error.
    case generationFailed(String)
}

// MARK: - Conditional implementation

#if canImport(MLX) && canImport(MLXLLM)
import MLX
import MLXLLM
import MLXNN
import MLXRandom

/// An ``LLMProvider`` backed by MLX Swift for local, on-device inference
/// with open-weight models.
///
/// This provider uses Apple's MLX framework to load and run models
/// entirely on-device — no network calls are required after the initial
/// model download.  It supports any model compatible with MLX Swift's
/// `LLMModel` / `ModelContainer` infrastructure, including quantised
/// variants.
///
/// ## Dependency gating
///
/// The entire implementation is wrapped in `#if canImport(MLX)`.  When
/// the `mlx-swift` package is not linked, a stub implementation is
/// compiled instead that throws ``MLXProviderError/unavailable`` on
/// every call.  This keeps the `XAgentCore` library compilable on
/// systems that do not have MLX Swift installed.
///
/// ## Usage
///
/// ```swift
/// #if canImport(MLX)
/// let provider = try MLXProvider(
///     modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
///     maxTokens: 1024,
///     temperature: 0.7
/// )
/// let response = try await provider.complete(prompt: "Explain MLX in three words.")
/// #endif
/// ```
public struct MLXProvider: LLMProvider {
    /// The loaded MLX model container (tokenizer + weights + config).
    private let modelContainer: ModelContainer

    /// Maximum tokens to generate per completion.
    private let maxTokens: Int

    /// Sampling temperature.  0 = greedy (deterministic).
    private let temperature: Float

    /// Optional PRNG seed for reproducible generation.
    private let seed: UInt64?

    // MARK: - Initialization

    /// Creates a new MLX-backed LLM provider.
    ///
    /// - Parameters:
    ///   - modelID: HuggingFace model identifier
    ///     (e.g. `"mlx-community/Llama-3.2-3B-Instruct-4bit"`) or a
    ///     local directory path containing `config.json` + weights.
    ///   - maxTokens: Maximum tokens to generate per completion.
    ///     Default 1024.
    ///   - temperature: Sampling temperature; 0 = greedy.  Default 0.7.
    ///   - seed: Optional PRNG seed for reproducible output.  When
    ///     `nil` generation is non-deterministic.
    /// - Throws: ``MLXProviderError/modelLoadFailed`` if the model
    ///   cannot be loaded.
    public init(
        modelID: String,
        maxTokens: Int = 1024,
        temperature: Float = 0.7,
        seed: UInt64? = nil
    ) throws {
        self.maxTokens = maxTokens
        self.temperature = max(0, temperature)
        self.seed = seed

        let configuration = ModelConfiguration(id: modelID)
        do {
            self.modelContainer = try ModelContainer(
                configuration: configuration
            )
        } catch {
            throw MLXProviderError.modelLoadFailed(
                "Failed to load model '\(modelID)': \(error.localizedDescription)"
            )
        }
    }

    // MARK: - LLMProvider conformance

    public func complete(prompt: String) async throws -> String {
        let messages: [Message] = [
            .init(role: .user, content: prompt)
        ]

        let result = try await modelContainer.perform { context in
            try await context.generate(
                messages: messages,
                parameters: makeGenerateParameters()
            )
        }
        return result.output
    }

    public func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let messages: [Message] = [
                        .init(role: .user, content: prompt)
                    ]

                    try await modelContainer.perform { context in
                        let tokenStream = try await context.generateStream(
                            messages: messages,
                            parameters: makeGenerateParameters()
                        )

                        for try await token in tokenStream {
                            continuation.yield(token)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private helpers

    private func makeGenerateParameters() -> GenerateParameters {
        var params = GenerateParameters()
        params.maxTokens = maxTokens
        params.temperature = temperature

        if let seed = seed {
            MLXRandom.seed(seed)
        }

        return params
    }
}

#else
// MARK: - Stub implementation (MLX not linked)

/// Stub ``LLMProvider`` that throws ``MLXProviderError/unavailable`` on
/// every call.  Compiled when `mlx-swift` is not a dependency so that
/// `XAgentCore` still builds.
public struct MLXProvider: LLMProvider {
    private let modelID: String
    private let maxTokens: Int
    private let temperature: Float
    private let seed: UInt64?

    /// Creates a stub MLX provider.  All subsequent calls will throw
    /// ``MLXProviderError/unavailable``.
    ///
    /// - Parameters:
    ///   - modelID: Ignored (MLX not linked).
    ///   - maxTokens: Ignored.
    ///   - temperature: Ignored.
    ///   - seed: Ignored.
    public init(
        modelID: String,
        maxTokens: Int = 1024,
        temperature: Float = 0.7,
        seed: UInt64? = nil
    ) {
        self.modelID = modelID
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.seed = seed
    }

    public func complete(prompt: String) async throws -> String {
        throw MLXProviderError.unavailable
    }

    public func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: MLXProviderError.unavailable
            )
        }
    }
}
#endif
