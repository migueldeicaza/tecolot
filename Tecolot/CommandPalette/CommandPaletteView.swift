import AppKit
import SwiftUI

/// Declarative SwiftUI body hosted inside `CommandPalettePanel`.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            if model.currentScope.showsFooter {
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            applyFocusRequest()
        }
        .onChange(of: model.fieldFocusCount) {
            applyFocusRequest()
        }
        .onChange(of: fieldFocused) { _, isFocused in
            if isFocused, model.shouldPlaceCaretAtEndOnFocus || !model.query.isEmpty {
                let expectedQuery = model.query
                DispatchQueue.main.async {
                    guard model.query == expectedQuery else {
                        return
                    }
                    model.placeCaretAtEnd()
                }
            }
        }
    }

    private func applyFocusRequest() {
        fieldFocused = true
        if model.shouldPlaceCaretAtEndOnFocus || !model.query.isEmpty {
            let focusGeneration = model.fieldFocusCount
            let expectedQuery = model.query
            model.placeCaretAtEnd()
            // Reapply on the next turn in case AppKit's field editor selected all text on becoming first responder.
            DispatchQueue.main.async {
                guard model.fieldFocusCount == focusGeneration, model.query == expectedQuery else {
                    return
                }
                model.placeCaretAtEnd()
            }
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: {
                model.query
            },
            set: { newValue in
                model.updateQueryFromTyping(newValue)
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            if let chipTitle = model.currentScope.chipTitle, !chipTitle.isEmpty {
                Button {
                    model.pop()
                } label: {
                    Text(chipTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(
                            Color.accentColor.opacity(0.24),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("Press Backspace or click to return")
                .accessibilityLabel("Scope: \(chipTitle)")
                .padding(.leading, 6)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                    .padding(.leading, 9)
            }

            TextField(
                "",
                text: queryBinding,
                selection: $model.textSelection,
                prompt: Text(model.currentScope.placeholder).foregroundStyle(.secondary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .autocorrectionDisabled()
            .focused($fieldFocused)
            .frame(minWidth: 100, maxWidth: .infinity)
            .accessibilityLabel("Command Palette Search")

            if !model.query.isEmpty {
                Button {
                    model.clearQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .padding(.trailing, 8)
            }
        }
        .padding(.trailing, model.query.isEmpty ? 10 : 0)
        .frame(height: CommandPaletteMetrics.inputHeight)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: CommandPaletteMetrics.inputCornerRadius, style: .continuous)
        )
        .padding(.horizontal, CommandPaletteMetrics.horizontalInset)
        .padding(.top, CommandPaletteMetrics.headerTopInset)
        .padding(.bottom, CommandPaletteMetrics.headerBottomInset)
    }

    // MARK: - Results List

    private struct IdentifiedItem: Identifiable {
        let index: Int
        let item: PaletteDisplayItem
        let id: String
    }

    private var identifiedItems: [IdentifiedItem] {
        model.items.enumerated().map { index, item in
            IdentifiedItem(index: index, item: item, id: itemID(item, index: index))
        }
    }

    private static let topAnchorID = "__palette_top__"
    private static let bottomAnchorID = "__palette_bottom__"

    private struct ScrollViewport: Equatable {
        let offsetY: CGFloat
        let height: CGFloat
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: CommandPaletteMetrics.listTopPadding)
                        .id(Self.topAnchorID)

                    ForEach(identifiedItems) { entry in
                        itemView(entry.item, index: entry.index)
                            .id(entry.id)
                    }

                    Color.clear
                        .frame(
                            height: model.currentScope.showsFooter
                                ? CommandPaletteMetrics.listBottomPaddingWithFooter
                                : CommandPaletteMetrics.listBottomPaddingWithoutFooter
                        )
                        .id(Self.bottomAnchorID)
                }
            }
            .onScrollGeometryChange(for: ScrollViewport.self) { geometry in
                ScrollViewport(
                    offsetY: geometry.visibleRect.minY,
                    height: geometry.visibleRect.height
                )
            } action: { _, newValue in
                model.updateScrollViewport(offsetY: newValue.offsetY, height: newValue.height)
            }
            .accessibilityLabel("Command Palette Results")
            .onChange(of: model.revealCount) {
                if let targetID = scrollTargetID() {
                    proxy.scrollTo(targetID, anchor: model.revealAnchor)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func itemID(_ item: PaletteDisplayItem, index: Int) -> String {
        switch item {
        case .row(let row):
            row.id
        case .sectionHeader(let title):
            "header.\(title).\(index)"
        case .divider:
            "divider.\(index)"
        case .hint(let message):
            "hint.\(message).\(index)"
        }
    }

    private func scrollTargetID() -> String? {
        guard let selectedIndex = model.selectedIndex, model.items.indices.contains(selectedIndex) else {
            return nil
        }
        // When selecting the first or last selectable item, scroll to the matching list edge so
        // padding and any leading section header never stay clipped offscreen.
        let firstSelectable = model.items.firstIndex(where: \.isSelectable)
        if selectedIndex == firstSelectable, model.revealAnchor != .bottom {
            return Self.topAnchorID
        }
        let lastSelectable = model.items.lastIndex(where: \.isSelectable)
        if selectedIndex == lastSelectable, model.revealAnchor != .top {
            return Self.bottomAnchorID
        }
        return itemID(model.items[selectedIndex], index: selectedIndex)
    }

    @ViewBuilder
    private func itemView(_ item: PaletteDisplayItem, index: Int) -> some View {
        switch item {
        case .sectionHeader(let title):
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .frame(height: CommandPaletteMetrics.sectionHeaderHeight, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

        case .divider:
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.35))
                .frame(height: 1)
                .padding(.horizontal, 12)
                .frame(height: CommandPaletteMetrics.dividerHeight)

        case .hint(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .frame(height: CommandPaletteMetrics.hintHeight)

        case .row(let row):
            let selected = model.selectedIndex == index
            rowView(row, selected: selected)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active = phase {
                        model.hoverIndex(index)
                    }
                }
                .onTapGesture {
                    model.execute(at: index)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.subtitle.map {
                    "\(row.title), \($0)"
                } ?? row.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
    }

    @ViewBuilder
    private func rowView(_ row: PaletteRow, selected: Bool) -> some View {
        let baseColor: Color = selected ? .white : .primary
        let highlightColor: Color = selected ? .white : .accentColor
        let secondaryColor: Color = selected ? .white.opacity(0.9) : .secondary

        Group {
            switch row.style {
            case .standard(_, let icon, let accessory):
                HStack(spacing: 8) {
                    if let icon {
                        iconView(icon, size: 16, tint: selected ? .white : .secondary)
                    }
                    Text(CommandPaletteSearch.attributedString(
                        row.title,
                        matchRanges: row.matchRanges,
                        font: .system(size: 13, weight: .regular),
                        highlightFont: .system(size: 13, weight: .semibold),
                        baseColor: baseColor,
                        highlightColor: highlightColor
                    ))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 8)
                    accessoryView(accessory, primaryColor: baseColor, secondaryColor: secondaryColor)
                }
                .padding(.horizontal, 10)
                .frame(height: CommandPaletteMetrics.rowHeight - 2)

            case .twoLine(_, let subtitle, let icon, let accessory):
                HStack(spacing: 10) {
                    iconView(icon ?? .symbol("terminal"), size: 20, tint: selected ? .white : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CommandPaletteSearch.attributedString(
                            row.title,
                            matchRanges: row.matchRanges,
                            font: .system(size: 13, weight: .regular),
                            highlightFont: .system(size: 13, weight: .semibold),
                            baseColor: baseColor,
                            highlightColor: highlightColor
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)

                        Text(CommandPaletteSearch.attributedString(
                            subtitle,
                            matchRanges: row.subtitleMatchRanges,
                            font: .system(size: 11.5, weight: .regular),
                            highlightFont: .system(size: 11.5, weight: .semibold),
                            baseColor: selected ? .white.opacity(0.86) : .secondary,
                            highlightColor: highlightColor
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    if accessory == .checkmark {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(baseColor)
                            .frame(width: 14, height: 14)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: CommandPaletteMetrics.twoLineRowHeight - 2)
            }
        }
        .background(
            selected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: CommandPaletteMetrics.selectionPillCornerRadius, style: .continuous)
        )
        .padding(.horizontal, CommandPaletteMetrics.horizontalInset)
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func iconView(_ icon: PaletteIcon, size: CGFloat, tint: Color) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.78, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .image(let nsImage):
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func accessoryView(
        _ accessory: PaletteRowAccessory,
        primaryColor: Color,
        secondaryColor: Color
    ) -> some View {
        switch accessory {
        case .none:
            EmptyView()
        case .shortcut(let shortcut):
            Text(shortcut)
                .font(.system(size: 12.5))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        case .status(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        case .checkmark:
            Image(systemName: "checkmark")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(primaryColor)
                .frame(width: 14, height: 14)
        case .returnGlyph:
            Image(systemName: "return")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(primaryColor)
                .frame(width: 14, height: 14)
        case .chevron(let detail, let shortcut):
            HStack(spacing: 6) {
                if let text = shortcut ?? detail, !text.isEmpty {
                    Text(text)
                        .font(.system(size: shortcut != nil ? 12.5 : 12))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: shortcut != nil, vertical: false)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .frame(width: 14, height: 14)
            }
            .layoutPriority(1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.35))
                .frame(height: 1)

            HStack(spacing: 6) {
                Spacer()
                Text("Action")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .background(
                        Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                    )
                    .accessibilityHidden(true)
            }
            .opacity(model.selectedRow != nil ? 1.0 : 0.42)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
        }
        .frame(height: CommandPaletteMetrics.footerHeight)
    }
}
