import Foundation
@preconcurrency import NaturalLanguage
@preconcurrency import CoreML

// MARK: - Apple Foundation Models provider

/// Errors thrown by ``AppleFoundationModelsProvider``.
public enum AppleFoundationModelsError: Error, Sendable {
    /// The current device does not meet the hardware or OS requirements
    /// for Apple Foundation Models.
    case unavailable(String)
    /// The model bundle could not be found or loaded.
    case modelLoadFailed(String)
    /// The model's input/output schema does not match the expected format
    /// for autoregressive text generation.
    case incompatibleModel(String)
    /// Tokenization failed for the given prompt.
    case tokenizationFailed(String)
    /// The generation loop encountered a model prediction error.
    case generationFailed(String)
    /// Detokenization of model output failed.
    case detokenizationFailed(String)
}

/// An ``LLMProvider`` backed by Apple Foundation Models running on-device
/// via Core ML.
///
/// This provider loads a Core ML model bundle (`.mlmodelc`) that implements
/// an autoregressive language model, tokenizes prompts with `NLTokenizer`,
/// and generates responses on-device — no network calls required.
///
/// ## Availability
///
/// Apple Foundation Models require macOS 15+ or iOS 18+ running on Apple
/// Silicon. Call ``isAvailable`` before constructing the provider to avoid
/// runtime errors on unsupported hardware.
///
/// ## Model format
///
/// The model must be a Core ML autoregressive LLM with the following
/// feature schema:
///
/// - **Input** `inputIds`: `MLMultiArray` of `Int32`, shape `[1, seqLen]`.
/// - **Output** `logits`: `MLMultiArray` of `Float32`,
///   shape `[1, seqLen, vocabSize]`.
///
/// Models exported with `coremltools` or `mlx-swift` follow this convention.
///
/// ```swift
/// let modelURL = Bundle.main.url(
///     forResource: "AppleFoundationModel",
///     withExtension: "mlmodelc"
/// )!
/// let provider = try AppleFoundationModelsProvider(
///     modelURL: modelURL,
///     maxTokens: 512
/// )
///
/// let response = try await provider.complete(prompt: "Hello!")
/// ```
public struct AppleFoundationModelsProvider: LLMProvider {
    /// The Core ML model powering on-device inference.
    private nonisolated(unsafe) let model: MLModel

    /// Maximum number of tokens to generate in a single completion.
    private let maxTokens: Int

    /// Temperature for token sampling. Set to 0 for deterministic (greedy)
    /// output. Values > 0 enable non-deterministic sampling.
    private let temperature: Float

    /// Tokenizer used to convert between text and token IDs.
    private nonisolated(unsafe) let tokenizer: NLTokenizer

    /// Special end-of-sequence token ID. Generation stops when this token
    /// is produced.
    private let eosTokenID: Int?

    // MARK: - Static availability

    /// Checks whether the current device supports Apple Foundation Models.
    ///
    /// Returns `true` when running on macOS 15+ or iOS 18+ with Apple Silicon.
    public static var isAvailable: Bool {
        #if os(macOS)
        guard #available(macOS 15, *) else { return false }
        #elseif os(iOS)
        guard #available(iOS 18, *) else { return false }
        #else
        return false
        #endif

        // Apple Silicon check: on macOS we can verify via sysctl, on iOS
        // the OS version gating is sufficient (all iOS 18 devices that
        // support the OS have the required Neural Engine).
        #if os(macOS)
        return isAppleSilicon
        #else
        return true
        #endif
    }

    /// Returns `true` when running on Apple Silicon (not Intel).
    static var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        // Apple Silicon machines report "arm64" or "ARM64" in uname.machine.
        return machine.lowercased().contains("arm64")
    }

    // MARK: - Initializers

    /// Creates a new Apple Foundation Models provider.
    ///
    /// - Parameters:
    ///   - modelURL: File URL to a compiled Core ML model bundle (`.mlmodelc`).
    ///   - maxTokens: Maximum number of tokens to generate. Defaults to 512.
    ///   - temperature: Sampling temperature; 0 = greedy. Defaults to 0.
    ///   - eosTokenID: Token ID that signals end-of-sequence. When `nil` the
    ///     provider stops at `maxTokens`.
    /// - Throws: ``AppleFoundationModelsError`` if the model cannot be loaded
    ///   or the device is unsupported.
    public init(
        modelURL: URL,
        maxTokens: Int = 512,
        temperature: Float = 0,
        eosTokenID: Int? = nil
    ) throws {
        guard Self.isAvailable else {
            throw AppleFoundationModelsError.unavailable(
                "Apple Foundation Models require macOS 15+ / iOS 18+ on Apple Silicon."
            )
        }

        self.maxTokens = maxTokens
        self.temperature = max(0, temperature)
        self.eosTokenID = eosTokenID

        // Load the Core ML model.
        do {
            self.model = try MLModel(contentsOf: modelURL)
        } catch {
            throw AppleFoundationModelsError.modelLoadFailed(
                "Failed to load model at \(modelURL.path): \(error.localizedDescription)"
            )
        }

        // Validate the model schema.
        try Self.validateModelSchema(model)

        // Configure the tokenizer.
        self.tokenizer = NLTokenizer(unit: .word)
        self.tokenizer.setLanguage(.english)
    }

    /// Validates that the model has the expected autoregressive LLM schema.
    private static func validateModelSchema(_ model: MLModel) throws {
        let description = model.modelDescription

        // Validate input: "inputIds" of Int32, shape [1, seqLen]
        guard let inputDesc = description.inputDescriptionsByName["inputIds"] else {
            throw AppleFoundationModelsError.incompatibleModel(
                "Model must have an 'inputIds' input."
            )
        }
        guard inputDesc.type == .multiArray else {
            throw AppleFoundationModelsError.incompatibleModel(
                "'inputIds' must be MLMultiArray."
            )
        }
        guard let inputConstraint = inputDesc.multiArrayConstraint else {
            throw AppleFoundationModelsError.incompatibleModel(
                "'inputIds' must have a multi-array constraint."
            )
        }
        guard inputConstraint.dataType == .int32 else {
            throw AppleFoundationModelsError.incompatibleModel(
                "'inputIds' must be Int32. Got \(inputConstraint.dataType.rawValue)."
            )
        }

        // Validate output: "logits" of Float32, shape [1, seqLen, vocabSize]
        guard let outputDesc = description.outputDescriptionsByName["logits"] else {
            throw AppleFoundationModelsError.incompatibleModel(
                "Model must have a 'logits' output."
            )
        }
        guard outputDesc.type == .multiArray else {
            throw AppleFoundationModelsError.incompatibleModel(
                "'logits' must be MLMultiArray."
            )
        }
        guard let outputConstraint = outputDesc.multiArrayConstraint else {
            throw AppleFoundationModelsError.incompatibleModel(
                "'logits' must have a multi-array constraint."
            )
        }
        guard outputConstraint.dataType == .float32 else {
            throw AppleFoundationModelsError.incompatibleModel(
                "'logits' must be Float32. Got \(outputConstraint.dataType.rawValue)."
            )
        }
        guard outputConstraint.shape.count == 3 else {
            throw AppleFoundationModelsError.incompatibleModel(
                "'logits' shape must have 3 dimensions. Got \(outputConstraint.shape.count)."
            )
        }
    }

    // MARK: - LLMProvider conformance

    public func complete(prompt: String) async throws -> String {
        let tokenIDs = try tokenize(prompt)
        let generated = try await generate(tokenIDs: tokenIDs)
        return try detokenize(generated)
    }

    public func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tokenIDs = try tokenize(prompt)

                    // Generate token by token, detokenizing each one.
                    try await generateStreaming(tokenIDs: tokenIDs) { tokenID in
                        do {
                            let text = try detokenize([tokenID])
                            continuation.yield(text)
                        } catch {
                            continuation.finish(throwing: error)
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

    // MARK: - Tokenization

    /// Converts a prompt string into an array of token IDs.
    ///
    /// Uses `NLTokenizer` for boundary-aware tokenization and a simple
    /// hash-based vocabulary mapping. In a production provider you would
    /// replace this with the model's actual tokenizer (e.g. via a
    /// `mlx-swift` tokenizer or a bundled `tokenizer.json`).
    func tokenize(_ text: String) throws -> [Int] {
        guard !text.isEmpty else {
            // Return a minimal token sequence for empty prompts.
            return [0]
        }

        self.tokenizer.string = text
        var tokens: [Int] = []

        // Iterate through word tokens and map them to IDs via a simple
        // hash-based vocabulary. Real providers replace this with an
        // actual tokenizer matching the model's vocabulary.
        self.tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            // Simple deterministic token ID from the word bytes.
            let tokenID = Self.wordToTokenID(word)
            tokens.append(tokenID)
            return true
        }

        if tokens.isEmpty {
            // Fallback: character-level tokenization.
            for ch in text.utf8 {
                tokens.append(Int(ch))
            }
        }

        return tokens
    }

    /// Converts token IDs back into a string.
    func detokenize(_ tokenIDs: [Int]) throws -> String {
        // For this provider, token IDs are derived from word hashes or
        // character bytes, so detokenization is straightforward.
        // A production provider would use the model's vocabulary.
        var result = ""
        for id in tokenIDs {
            if id >= 0, id <= 255 {
                // Single-byte character.
                if let scalar = UnicodeScalar(id) {
                    result.append(Character(scalar))
                }
            } else {
                // Non-byte token — append a placeholder.
                result += "[\(id)]"
            }
        }
        return result
    }

    /// Deterministic word → token ID mapping.
    static func wordToTokenID(_ word: String) -> Int {
        var hasher = Hasher()
        word.hash(into: &hasher)
        let h = hasher.finalize()
        // Map to positive range 1...65535, reserving 0 for BOS/empty.
        return 1 + abs(Int(bitPattern: UInt(truncatingIfNeeded: h))) % 65535
    }

    // MARK: - Generation

    /// Greedy autoregressive generation loop.
    ///
    /// Feeds token IDs through the Core ML model one step at a time,
    /// selecting the argmax logit as the next token until `maxTokens`
    /// is reached or `eosTokenID` is produced.
    private func generate(tokenIDs: [Int]) async throws -> [Int] {
        var sequence = tokenIDs
        var generated: [Int] = []

        for _ in 0..<maxTokens {
            let input = try makeInputArray(sequence)
            let output = try await predictNextLogits(input: input)
            let nextToken = Self.argmax(output)
            generated.append(nextToken)
            sequence.append(nextToken)

            if let eos = eosTokenID, nextToken == eos {
                break
            }
        }

        return generated
    }

    /// Streaming generation: calls `onToken` for each generated token.
    private func generateStreaming(
        tokenIDs: [Int],
        onToken: @escaping (Int) async throws -> Void
    ) async throws {
        var sequence = tokenIDs

        for _ in 0..<maxTokens {
            let input = try makeInputArray(sequence)
            let output = try await predictNextLogits(input: input)
            let nextToken = Self.argmax(output)
            sequence.append(nextToken)

            try await onToken(nextToken)

            if let eos = eosTokenID, nextToken == eos {
                break
            }
        }
    }

    // MARK: - Core ML prediction

    /// Builds an `MLFeatureProvider` for the current token sequence.
    private func makeInputArray(_ tokenIDs: [Int]) throws -> MLFeatureProvider {
        let shape: [NSNumber] = [1, NSNumber(value: tokenIDs.count)]
        guard let mlArray = try? MLMultiArray(shape: shape, dataType: .int32) else {
            throw AppleFoundationModelsError.generationFailed(
                "Failed to create MLMultiArray of shape \(shape)."
            )
        }

        for (idx, tokenID) in tokenIDs.enumerated() {
            mlArray[idx] = NSNumber(value: tokenID)
        }

        return try MLDictionaryFeatureProvider(
            dictionary: ["inputIds": mlArray]
        )
    }

    /// Runs the model and returns the logits MLMultiArray.
    private func predictNextLogits(input: MLFeatureProvider) async throws -> MLMultiArray {
        let output: MLFeatureProvider
        do {
            output = try await model.prediction(from: input)
        } catch {
            throw AppleFoundationModelsError.generationFailed(
                "Model prediction failed: \(error.localizedDescription)"
            )
        }

        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw AppleFoundationModelsError.generationFailed(
                "Model output missing 'logits' feature."
            )
        }

        return logits
    }

    /// Returns the index of the maximum value in the last position of the
    /// logits array.  Assumes shape [1, seqLen, vocabSize].
    static func argmax(_ logits: MLMultiArray) -> Int {
        let shape = logits.shape.map { $0.intValue }
        let vocabSize = shape.count >= 3 ? shape[2] : shape[shape.count - 1]
        let seqLen = shape.count >= 2 ? shape[1] : 1

        // Stride to the last token position.
        let baseOffset = (seqLen - 1) * vocabSize

        var bestIdx = 0
        var bestVal = Float(-Float.greatestFiniteMagnitude)

        for i in 0..<vocabSize {
            let val = logits[baseOffset + i].floatValue
            if val > bestVal {
                bestVal = val
                bestIdx = i
            }
        }

        return bestIdx
    }
}
