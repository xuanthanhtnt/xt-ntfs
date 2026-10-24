import SwiftUI
import XTShared

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var ntfs: [Volume] { model.volumes.filter { $0.isNTFS } }
    var others: [Volume] { model.volumes.filter { !$0.isNTFS } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !ntfs.isEmpty {
                        section(NSLocalizedString("NTFS Volumes", comment: ""), ntfs)
                    }
                    section(NSLocalizedString("Other Volumes", comment: ""), others)
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            footer
        }
        .background(LinearGradient(colors: [Theme.sidebarTop, Theme.sidebarBottom],
                                   startPoint: .top, endPoint: .bottom))
        .foregroundStyle(Theme.sidebarText)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 1) {
                Text(NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(engineColor).frame(width: 6, height: 6)
                    Text(engineText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.sidebarSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 38)
        .padding(.bottom, 12)
    }

    private var engineColor: Color {
        switch model.installState {
        case .running: return model.config.driverEnabled ? Theme.statusRW : Theme.statusRO
        case .unknown: return Theme.statusOff
        default: return Theme.statusRO
        }
    }

    private var engineText: String {
        switch model.installState {
        case .running:
            return model.config.driverEnabled ? NSLocalizedString("XT NTFS driver enabled", comment: "")
                                              : NSLocalizedString("XT NTFS driver disabled", comment: "")
        case .notInstalled: return NSLocalizedString("Engine not installed", comment: "")
        case .outdated: return NSLocalizedString("Engine update required", comment: "")
        case .notResponding: return NSLocalizedString("Engine not responding", comment: "")
        case .unknown: return NSLocalizedString("Checking engine…", comment: "")
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [Volume]) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.sidebarSection)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
        ForEach(list) { v in
            SidebarRow(volume: v, selected: model.selection == .volume(v.id))
                .onTapGesture { model.selection = .volume(v.id) }
        }
    }

    private var footer: some View {
        Button {
            model.selection = .engine
        } label: {
            HStack(spacing: 12) {
                AppGlyph(size: 26)
                Text("XT NTFS")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if model.installState != .running && model.installState != .unknown {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.statusRO)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .frame(maxWidth: .infinity)
            .background(model.selection == .engine ? Theme.sidebarSelection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.sidebarFooter)
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    var volume: Volume
    var selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: volume.status)
            DriveGlyph(volume: volume, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(Format.size(volume.displaySize))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sidebarSecondary)
                    if volume.isMounted && volume.readOnly {
                        TagBadge(text: "read-only", foreground: Color(white: 0.15), background: .white.opacity(0.9))
                    }
                    if volume.noBrowse {
                        TagBadge(text: "nobrowse", foreground: Color(white: 0.15), background: Color.orange)
                    }
                    if volume.mountedByXT {
                        TagBadge(text: "XT", foreground: .white, background: Theme.badgeNTFS)
                    }
                }
            }
            Spacer(minLength: 4)
            if let activity = model.busy[volume.bsdName] {
                ProgressView().controlSize(.small).help(activity)
            } else if volume.isEjectable && volume.isMounted && !volume.isInternal {
                Button {
                    Task { await model.eject(volume) }
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.sidebarSecondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Eject", comment: ""))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(height: 50)
        .background(selected ? Theme.sidebarSelection : (hovering ? Theme.sidebarHover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { VolumeMenu(volume: volume) }
    }
}

/// Context menu shared by the sidebar and the menu bar.
struct VolumeMenu: View {
    @EnvironmentObject var model: AppModel
    var volume: Volume

    var body: some View {
        if volume.isMounted {
            Button(NSLocalizedString("Open in Finder", comment: "")) { model.reveal(volume) }
            if volume.canUnmount {
                Button(NSLocalizedString("Unmount", comment: "")) { Task { await model.unmount(volume) } }
            }
        } else {
            Button(NSLocalizedString("Mount", comment: "")) { Task { await model.mount(volume) } }
            if volume.isNTFS {
                Button(NSLocalizedString("Mount Read-only", comment: "")) { Task { await model.mount(volume, readOnly: true) } }
            }
        }
        if volume.canVerify {
            Button(NSLocalizedString("Verify", comment: "")) { Task { await model.verify(volume) } }
        }
        if volume.isEjectable && !volume.isInternal {
            Divider()
            Button(NSLocalizedString("Eject", comment: "")) { Task { await model.eject(volume) } }
        }
    }
}

/// The app glyph drawn in SwiftUI (used in the sidebar footer and About).
struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(LinearGradient(colors: [Color(nsColor: Color.rgb(92, 136, 255)), Color(nsColor: Color.rgb(48, 70, 170))],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: size * 0.06) {
                RoundedRectangle(cornerRadius: size * 0.05).fill(.white.opacity(0.95))
                    .frame(width: size * 0.62, height: size * 0.16)
                RoundedRectangle(cornerRadius: size * 0.05).fill(.white.opacity(0.75))
                    .frame(width: size * 0.62, height: size * 0.16)
                RoundedRectangle(cornerRadius: size * 0.05).fill(.white.opacity(0.55))
                    .frame(width: size * 0.62, height: size * 0.16)
            }
        }
        .frame(width: size, height: size)
    }
}
