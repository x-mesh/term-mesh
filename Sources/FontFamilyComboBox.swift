import SwiftUI

/// One control for choosing a font family: a button that shows the current
/// choice and opens a searchable list under it.
struct FontFamilyComboBox: View {
    @Binding var selection: String
    /// Title of the row that clears the selection.
    let emptyTitle: LocalizedStringKey
    /// Font families in display order. A divider separates the sections.
    let sections: [[String]]
    let accessibilityLabel: LocalizedStringKey

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                title(for: selection)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: FontFamilyComboBoxStyle.controlHeight)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(title(for: selection))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FontFamilyComboBoxList(
                selection: $selection,
                emptyTitle: emptyTitle,
                sections: sections,
                dismiss: { isPresented = false }
            )
        }
    }

    private func title(for family: String) -> Text {
        family.isEmpty ? Text(emptyTitle) : Text(verbatim: family)
    }
}

private enum FontFamilyComboBoxStyle {
    static let controlHeight: CGFloat = 24
    static let listWidth: CGFloat = 280
    static let listHeight: CGFloat = 280
    static let rowHeight: CGFloat = 22
}

private struct FontFamilyComboBoxList: View {
    private typealias Style = FontFamilyComboBoxStyle

    @Binding var selection: String
    let emptyTitle: LocalizedStringKey
    let sections: [[String]]
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var isSearchFocused: Bool

    private var groups: [[String]] {
        FontFamilySearch.groups(sections: sections, selection: selection, query: query)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search installed fonts", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .onSubmit { choose(highlighted ?? groups.first?.first) }
                        .backport.onKeyPress(.downArrow) { _ in
                            moveHighlight(by: 1, proxy: proxy)
                            return .handled
                        }
                        .backport.onKeyPress(.upArrow) { _ in
                            moveHighlight(by: -1, proxy: proxy)
                            return .handled
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                            if index > 0 {
                                Divider().padding(.vertical, 4)
                            }
                            ForEach(group, id: \.self) { family in
                                row(family)
                            }
                        }
                        if groups.isEmpty {
                            Text("No matching fonts")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: Style.rowHeight)
                        }
                    }
                    .padding(4)
                }
                .frame(height: Style.listHeight)
            }
            .frame(width: Style.listWidth)
            .onAppear {
                isSearchFocused = true
                highlighted = selection
                proxy.scrollTo(selection, anchor: .center)
            }
            .onChange(of: query) { _ in
                highlighted = groups.first?.first
            }
        }
    }

    private func row(_ family: String) -> some View {
        let isHighlighted = family == highlighted
        return Button {
            choose(family)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(family == selection ? 1 : 0)
                (family.isEmpty ? Text(emptyTitle) : Text(verbatim: family))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: Style.rowHeight)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { highlighted = family }
        }
        .accessibilityAddTraits(family == selection ? .isSelected : [])
        .id(family)
    }

    private func moveHighlight(by delta: Int, proxy: ScrollViewProxy) {
        highlighted = FontFamilySearch.moved(from: highlighted, by: delta, in: groups.flatMap { $0 })
        if let highlighted {
            proxy.scrollTo(highlighted)
        }
    }

    private func choose(_ family: String?) {
        guard let family else { return }
        selection = family
        dismiss()
    }
}
