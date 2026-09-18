import SwiftUI
import StemExporterKit

struct SessionSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.openWindow) private var openWindow
    @State private var showingParts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionSection
            templatesSection
            Spacer(minLength: 0)
            appearanceFooter
        }
        .padding(.vertical, 16)
        .frame(width: 240)
        .background(palette.sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.separator).frame(width: 1)
        }
        .sheet(isPresented: $showingParts) { SessionPartsSheet() }
    }

    // MARK: Session

    @ViewBuilder
    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Session")

            if let session = model.session {
                VStack(spacing: 2) {
                    InfoRow(label: "Parts", value: "\(session.includedParts.count) file\(session.includedParts.count == 1 ? "" : "s")")
                    if let first = session.includedParts.first, let last = session.includedParts.last {
                        HStack {
                            Text(session.includedParts.count == 1
                                 ? first.name
                                 : "\(first.name) → \(last.name)")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.secondaryLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                    }
                    InfoRow(label: "Duration", value: Timecode.compactDuration(session.totalDuration))
                    InfoRow(
                        label: "Tracks",
                        value: "\(session.trackCount) (\(session.format.shortDescription))"
                    )
                }

                Button {
                    showingParts = true
                } label: {
                    Label("Session Parts…", systemImage: "square.stack.3d.down.right")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.link)
                .padding(.top, 2)

                if !session.warnings.isEmpty {
                    ForEach(session.warnings) { warning in
                        WarningChip(warning: warning)
                    }
                }
            } else {
                Text("No session loaded")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.tertiaryLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.separator).frame(height: 1)
        }
    }

    // MARK: Templates

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("Templates")
                Spacer()
                Button {
                    model.editingTemplate = Template.placeholder(
                        name: TemplateStore.uniqueName(base: "New Template", among: model.templates.map(\.name)),
                        trackCount: model.session?.trackCount ?? 32
                    )
                    openWindow(id: WindowID.templateEditor)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.tertiaryLabel)
                }
                .buttonStyle(.plain)
                .help("New template")
            }
            .padding(.horizontal, 16)

            VStack(spacing: 2) {
                TemplateChip(
                    title: "No template",
                    icon: "minus.circle",
                    isSelected: model.selectedTemplateID == nil
                ) {
                    model.selectTemplate(nil)
                }

                ForEach(model.templates) { template in
                    TemplateChip(
                        title: template.name,
                        icon: "rectangle.split.3x1",
                        isSelected: model.selectedTemplateID == template.id,
                        subtitle: "\(template.trackCount) tracks"
                    ) {
                        model.selectTemplate(template.id)
                    }
                    .contextMenu {
                        Button("Edit…") {
                            model.editingTemplate = template
                            openWindow(id: WindowID.templateEditor)
                        }
                        Button("Duplicate") { _ = model.duplicateTemplate(template) }
                        Divider()
                        Button("Delete", role: .destructive) { model.deleteTemplate(template) }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 14)
    }

    // MARK: Footer

    private var appearanceFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryLabel)
            Text("Appearance: \(model.appearance.title)")
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryLabel)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

// MARK: - Pieces

struct SectionHeader: View {
    let title: String
    @Environment(\.palette) private var palette

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.4)
            .textCase(.uppercase)
            .foregroundStyle(palette.tertiaryLabel)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(palette.secondaryLabel)
            Spacer()
            Text(value)
                .foregroundStyle(palette.label)
        }
        .font(.system(size: 12.5))
    }
}

struct TemplateChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var subtitle: String?
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : palette.secondaryLabel)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : palette.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : palette.tertiaryLabel)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? palette.accent : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WarningChip: View {
    let warning: SessionWarning
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: warning.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 10))
            Text(warning.message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.warningLabel)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.warningBackground)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.warningBorder, lineWidth: 1))
        )
    }
}

// MARK: - Parts sheet

/// Filename order is almost always right, but when it isn't, the order has to be
/// correctable — and a stray file has to be removable — without re-recording.
struct SessionPartsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Session Parts")
                    .font(.system(size: 15, weight: .semibold))
                if let session = model.session {
                    Text(session.partsSummary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                }
                Text("Files are concatenated top to bottom. Drag to reorder if the filenames don’t sort the way the recorder wrote them.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider().overlay(palette.separator)

            if let session = model.session {
                List {
                    ForEach(Array(session.parts.enumerated()), id: \.element.id) { index, part in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(palette.quaternaryLabel)
                                .font(.system(size: 11))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(part.url.lastPathComponent)
                                    .font(.system(size: 13))
                                    .foregroundStyle(part.isExcluded ? palette.tertiaryLabel : palette.label)
                                Text("\(Timecode.compactDuration(part.duration)) · \(part.format.channelCount) ch · \(part.format.shortDescription)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.tertiaryLabel)
                            }
                            Spacer()
                            Toggle("Include", isOn: Binding(
                                get: { !part.isExcluded },
                                set: { model.setPartExcluded(!$0, at: index) }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        }
                        .opacity(part.isExcluded ? 0.45 : 1)
                        .padding(.vertical, 2)
                    }
                    .onMove { model.movePart(from: $0, to: $1) }
                }
                .listStyle(.inset)
                .frame(minHeight: 200)
            }

            Divider().overlay(palette.separator)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
        .background(palette.windowBackground)
    }
}
