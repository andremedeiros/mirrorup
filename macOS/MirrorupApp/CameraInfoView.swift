import MirrorupCapture
import SwiftUI

/// Display-ready camera metadata, built once each time the camera is read so view bodies only lay
/// out precomputed strings. Undocumented vendor codes are left out (they are in the diagnostics
/// export).
struct CameraInfoDisplay: Equatable {
    struct Section: Equatable, Identifiable {
        let kind: CameraMetadata.SectionKind
        let rows: [Row]
        var id: CameraMetadata.SectionKind { kind }
    }

    struct Row: Equatable, Identifiable {
        let id: CameraMetadata.ItemKind
        let label: String
        let value: String
        let raw: String
        /// Options the camera accepts, already joined for display; nil when there is no choice.
        let options: String?
        let optionCount: Int
        /// Long lists (capabilities) start collapsed behind their element count; nil for plain values.
        let listCount: Int?
        /// Lowercased label + value, for search.
        let searchText: String
    }

    let sections: [Section]
}

extension CameraInfoDisplay {
    init(_ metadata: CameraMetadata) {
        sections = metadata.documentedOnly.sections
            .sorted { $0.kind < $1.kind }
            .map { section in
                Section(kind: section.kind, rows: section.items.map { item in
                    Row(
                        id: item.kind,
                        label: item.label,
                        value: item.value,
                        raw: item.raw,
                        options: item.allowedValues.count > 1 ? item.allowedValues.joined(separator: ", ") : nil,
                        optionCount: item.allowedValues.count,
                        listCount: section.kind == .capabilities ? item.value.split(separator: ",").count : nil,
                        searchText: "\(item.label) \(item.value)".lowercased()
                    )
                })
            }
    }

    func filtered(by query: String) -> [Section] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let rows = section.rows.filter { $0.searchText.contains(query) }
            return rows.isEmpty ? nil : Section(kind: section.kind, rows: rows)
        }
    }
}

/// Search over the display model. Results and the coarse state are stored, so typing re-renders only
/// what reads them, and the window's structure changes only when `state` does.
@MainActor
@Observable
final class CameraInfoSearch {
    enum State: Equatable { case noCamera, noMatches, results }

    var query = "" {
        didSet { update() }
    }
    private(set) var results: [CameraInfoDisplay.Section] = []
    private(set) var state = State.noCamera
    private var display: CameraInfoDisplay?

    func setDisplay(_ display: CameraInfoDisplay?) {
        self.display = display
        update()
    }

    private func update() {
        results = display?.filtered(by: query) ?? []
        state = display == nil ? .noCamera : (results.isEmpty ? .noMatches : .results)
    }
}

/// Everything the camera reports, in human terms. Read when the window opens and on Refresh, never
/// continuously.
struct CameraInfoView: View {
    let model: AppModel
    @State private var search = CameraInfoSearch()

    var body: some View {
        CameraInfoResults(search: search, readAt: model.cameraInfoReadAt)
            .overlay { CameraInfoEmptyState(state: search.state) }
            .searchable(text: $search.query, placement: .toolbar, prompt: "Search settings")
            .toolbar {
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refreshCameraInfo() }
                    }
                    .disabled(model.isReadingCameraInfo)
                    .help("Read the camera's current settings")
                }
            }
            .task { await model.refreshCameraInfo() }
            .onChange(of: model.cameraInfoRevision, initial: true) {
                search.setDisplay(model.cameraInfoDisplay)
            }
            .frame(minWidth: 440, minHeight: 400)
    }
}

private struct CameraInfoResults: View {
    let search: CameraInfoSearch
    let readAt: Date?

    var body: some View {
        Form {
            ForEach(search.results) { section in
                CameraInfoSection(section: section)
            }
            if let readAt, !search.results.isEmpty {
                Text("Read at \(readAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Shown over the (empty) form; `state` changes only when results appear or disappear.
private struct CameraInfoEmptyState: View {
    let state: CameraInfoSearch.State

    var body: some View {
        switch state {
        case .noCamera:
            ContentUnavailableView(
                "No Camera Connected",
                systemImage: "camera",
                description: Text("Turn on streaming with the camera connected, then press Refresh.")
            )
        case .noMatches:
            ContentUnavailableView.search
        case .results:
            EmptyView()
        }
    }
}

private struct CameraInfoSection: View {
    let section: CameraInfoDisplay.Section

    var body: some View {
        Section(section.kind.title) {
            ForEach(section.rows) { row in
                CameraInfoRow(label: row.label, value: row.value, raw: row.raw,
                              options: row.options, optionCount: row.optionCount, listCount: row.listCount)
            }
        }
    }
}

private struct CameraInfoRow: View {
    let label: String
    let value: String
    let raw: String
    let options: String?
    let optionCount: Int
    let listCount: Int?
    @State private var isExpanded = false

    var body: some View {
        if let listCount {
            DisclosureGroup(isExpanded: $isExpanded) {
                DetailText(text: value)
            } label: {
                LabeledContent(label, value: "\(listCount)")
            }
        } else if let options {
            DisclosureGroup(isExpanded: $isExpanded) {
                DetailText(text: options)
            } label: {
                ValueRow(label: label, value: value, raw: raw, footnote: "\(optionCount) options")
            }
        } else {
            ValueRow(label: label, value: value, raw: raw, footnote: nil)
        }
    }
}

private struct ValueRow: View {
    let label: String
    let value: String
    let raw: String
    let footnote: String?

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                if let footnote {
                    Text(footnote).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } label: {
            Text(label)
        }
        .help("Raw value: \(raw)")
    }
}

private struct DetailText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
