import SwiftUI

/// The single main window: a sidebar of pages, the selected page, and a message bar.
struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: AppLibraryModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(AppPage.allCases, selection: Binding<AppPage?>(get: { model.selectedPage }, set: { if let page = $0 { model.selectedPage = page } })) { page in
                    Label(page.title, systemImage: page.symbol)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(page)
                        .accessibilityIdentifier("page-" + page.title)
                }.listStyle(.sidebar).scrollContentBackground(.hidden).padding(.top, 8)
                StatusBadge(model: model).padding(12)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            .frame(maxHeight: .infinity)
            .background(.bar)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(model.selectedPage.title).font(.title2.weight(.semibold))
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("应用配置", systemImage: "checkmark.circle") { Task { await model.applySavedConfiguration() } }
                        .buttonStyle(.borderedProminent)
                        .help("校验已保存的节点、规则和高级选项；代理运行中时立即生效。")
                        .disabled(model.busy || library.migrationRequired)
                }.padding(.horizontal, 22).padding(.vertical, 16)
                Divider()
                if library.migrationRequired { migrationBanner }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
                MessageBar(model: model, library: library)
            }
            .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(WindowContentBoundary().frame(width: 0, height: 0))
    }

    @ViewBuilder private var page: some View {
        switch model.selectedPage {
        case .overview: OverviewView(model: model, library: library)
        case .library: LibraryView(model: model, library: library).disabled(library.migrationRequired)
        case .rules: RulesView(model: model, library: library).disabled(library.migrationRequired)
        case .connections: ConnectionsView(model: model)
        case .advanced: AdvancedView(model: model, library: library)
        }
    }

    private var migrationBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal").foregroundStyle(.orange)
            Text("检测到旧版钥匙串中的凭据，需要迁移到本机配置文件后才能继续编辑。")
            Spacer()
            Button("迁移旧配置") { model.perform { try library.migrateLegacyCredentials() } }
                .disabled(model.busy)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.orange.opacity(0.1))
    }
}

/// Compact service state at the bottom of the sidebar.
private struct StatusBadge: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.statusTint).frame(width: 8, height: 8)
            Text(model.phaseLabel).font(.callout.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("服务状态：" + model.phaseLabel)
    }
}

/// Errors and warnings need dismissal; success notices expire independently.
/// No `.textSelection` here: selectable text in this bar, which is inserted and removed
/// below the page, was sometimes drawn upside down. A copy button replaces selection.
private struct MessageBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: AppLibraryModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error ?? library.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(4)
                    Spacer()
                    copyButton(error)
                    Button("关闭") { model.dismissError() }.buttonStyle(.borderless)
                }
                .font(.callout).padding(.horizontal, 20).padding(.vertical, 12)
                .background(.orange.opacity(0.1))
            }
            if !model.pendingWarnings.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    ScrollView {
                        Text(model.pendingWarnings.joined(separator: "\n"))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(CGFloat(model.pendingWarnings.count) * 48, 160))
                    copyButton(model.pendingWarnings.joined(separator: "\n"))
                    Button("关闭警告") { model.dismissWarnings() }.buttonStyle(.borderless)
                }
                .font(.callout).padding(.horizontal, 20).padding(.vertical, 12)
                .background(.orange.opacity(0.1))
            }
            if model.error == nil, library.error == nil, !model.notice.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    Text(model.notice).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("关闭") { model.dismissNotice() }.buttonStyle(.borderless)
                }
                .font(.callout).padding(.horizontal, 20).padding(.vertical, 10)
                .background(.blue.opacity(0.08))
                .task(id: model.noticeID) {
                    let shown = model.noticeID
                    do { try await Task.sleep(for: .seconds(8)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    model.expireNotice(id: shown)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func copyButton(_ text: String) -> some View {
        Button("复制") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }.buttonStyle(.borderless)
    }
}
