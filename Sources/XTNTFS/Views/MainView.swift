import SwiftUI
import XTShared

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 290)
            Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 560)
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .sheet(item: $model.report) { r in
            ReportSheet(report: r).environmentObject(model)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .engine:
            EngineView()
        case .volume:
            if let v = model.selectedVolume {
                VolumeDetailView(volume: v)
                    .id(v.id)
            } else {
                placeholder
            }
        case .none:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("Connect a disk to get started", comment: ""))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.detailBackground)
    }
}
