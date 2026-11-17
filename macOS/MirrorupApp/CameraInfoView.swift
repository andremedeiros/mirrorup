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
        /// Long lists (capabilities) start collapsed behind their count.
        let isList: Bool
        /// Lowercased label + value, for search.
        let searchText: String
    }

    let sections: [Section]

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
                        isList: section.kind == .capabilities,
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

/// Everything the camera reports, in human terms. Read when the window opens and on Refresh, never
/// continuously.
struct CameraInfoView: View {
    let model: AppModel
    @State private var query = ""

    var body: some View {
        CameraInfoContent(display: model.cameraInfoDisplay, readAt: model.cameraInfoReadAt, query: query)
            .searchable(text: $query, placement: .toolbar, prompt: "Search settings")
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
            .frame(minWidth: 440, minHeight: 400)
    }
}

private struct CameraInfoContent: View {
    let display: CameraInfoDisplay?
    let readAt: Date?
    let query: String

    var body: some View {
        let sections = display?.filtered(by: query) ?? []
        if sections.isEmpty {
            if display == nil {
                ContentUnavailableView(
                    "No Camera Connected",
                    systemImage: "camera",
                    description: Text("Turn on streaming with the camera connected, then press Refresh.")
                )
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            Form {
                ForEach(sections) { section in
                    CameraInfoSection(section: section)
                }
                if let readAt {
                    Text("Read at \(readAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct CameraInfoSection: View {
    let section: CameraInfoDisplay.Section

    var body: some View {
        Section(section.kind.title) {
            ForEach(section.rows) { row in
                CameraInfoRow(label: row.label, value: row.value, raw: row.raw,
                              options: row.options, optionCount: row.optionCount, isList: row.isList)
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
    let isList: Bool
    @State private var isExpanded = false

    var body: some View {
        if isList {
            DisclosureGroup(isExpanded: $isExpanded) {
                DetailText(text: value)
            } label: {
                LabeledContent(label, value: "\(value.split(separator: ",").count)")
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
