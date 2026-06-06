import SwiftUI

/// The main content view for the XAgent control application.
///
/// Provides a text field for entering a task, buttons for submitting
/// (POST /runs) and streaming (SSE), and a scrollable event log.
struct ContentView: View {
    /// The API client targeting the daemon.
    private let client = APIClient(baseURL: URL(string: "http://localhost:8080")!)

    /// The user's task input.
    @State private var taskText: String = ""

    /// Accumulated stream events.
    @State private var events: [String] = []

    /// True while a request is in-flight.
    @State private var isBusy: Bool = false

    /// The result of a non-streaming submit.
    @State private var resultText: String = ""

    /// Any error message to display.
    @State private var errorText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Input area.
            HStack(spacing: 8) {
                TextField("Enter task…", text: $taskText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy)

                Button("Submit") {
                    submitTask()
                }
                .disabled(taskText.isEmpty || isBusy)
                .keyboardShortcut(.return, modifiers: [])

                Button("Stream") {
                    streamTask()
                }
                .disabled(taskText.isEmpty || isBusy)
                .keyboardShortcut(.return, modifiers: .command)
            }

            // Result area.
            if !resultText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result")
                        .font(.headline)
                    ScrollView {
                        Text(resultText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
            }

            // Error area.
            if !errorText.isEmpty {
                Text(errorText)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            // Event log.
            if !events.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stream Events")
                        .font(.headline)
                    List(events, id: \.self) { event in
                        Text(event)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    .listStyle(.plain)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Spacer()

            // Status bar.
            HStack {
                if isBusy {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 4)
                    Text("Working…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !events.isEmpty {
                    Text("\(events.count) event(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("Clear") {
                    events = []
                    resultText = ""
                    errorText = ""
                }
                .disabled(events.isEmpty && resultText.isEmpty && errorText.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
    }

    // MARK: - Actions

    /// Submits the current task via POST /runs and displays the result.
    private func submitTask() {
        let task = taskText.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty else { return }

        isBusy = true
        resultText = ""
        errorText = ""

        Task {
            do {
                let result = try await client.submit(task: task)
                resultText = result
            } catch {
                errorText = "Submit failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    /// Opens an SSE stream for the current task and displays events as
    /// they arrive.
    private func streamTask() {
        let task = taskText.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty else { return }

        isBusy = true
        errorText = ""
        events = []

        Task {
            do {
                let eventStream = client.stream(task: task)
                for try await event in eventStream {
                    events.append(event)
                }
            } catch {
                errorText = "Stream failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }
}
