import AppKit
import HighlightedTextEditor
import MarkdownUI
import SwiftUI

/// Renders the session summary. Defaults to a rich-text render that hides
/// the raw markdown syntax (`#`, `**`, list markers, etc.); a small toolbar
/// toggle swaps in a source view — `HighlightedTextEditor` with the
/// `.markdown` preset — for copying or inspecting the underlying markup.
///
/// Layout flips right-to-left when the dominant script is RTL.
struct SummaryMarkdownView: View {
    let text: String

    @State private var showSource = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if showSource {
                    sourceView
                } else {
                    richView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            toggleButton
                .padding(8)
        }
    }

    private var isRTL: Bool { TextDirection.isRightToLeft(text) }

    private var richView: some View {
        ScrollView {
            Markdown(text)
                .markdownTextStyle(\.text) {
                    FontSize(13)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
                .multilineTextAlignment(isRTL ? .trailing : .leading)
                .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var sourceView: some View {
        HighlightedTextEditor(text: readonlyBinding, highlightRules: .markdown)
            .introspect { editor in configure(editor.textView) }
            .background(Color(nsColor: .textBackgroundColor))
    }

    private var toggleButton: some View {
        Button {
            showSource.toggle()
        } label: {
            Image(systemName: showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.2)))
        .help(showSource ? "Show rendered markdown" : "Show markdown source")
        .accessibilityLabel(showSource ? "Show rendered markdown" : "Show markdown source")
    }

    /// `HighlightedTextEditor` requires a two-way binding. The `get` pins
    /// to the latest `text` so streaming updates propagate; writes are
    /// ignored because `isEditable` is `false`.
    private var readonlyBinding: Binding<String> {
        Binding(get: { text }, set: { _ in })
    }

    private func configure(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
        textView.alignment = isRTL ? .right : .left
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
    }
}
