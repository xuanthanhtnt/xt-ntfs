import SwiftUI
import AppKit
import XTShared

// MARK: - Drive icon

enum DriveIcons {
    private static let base = "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/"
    static let external = NSImage(contentsOfFile: base + "External.icns")
    static let internalDisk = NSImage(contentsOfFile: base + "Internal.icns")
    static let removable = NSImage(contentsOfFile: base + "Removable.icns")
    static let ntfs: NSImage? = {
        if let url = Bundle.main.url(forResource: "NTFSVolume", withExtension: "icns") {
            return NSImage(contentsOf: url)
        }
        return nil
    }()

    private static var cache: [String: NSImage] = [:]

    /// The icon macOS itself uses for the disk (like Paragon and Finder):
    /// the yellow USB drive for USB disks, the internal disk icon, etc.
    static func image(for v: Volume) -> NSImage? {
        // Mounted Mac volumes: Finder's icon (keeps custom volume icons).
        if let mp = v.mountPoint, !v.isNTFS { return NSWorkspace.shared.icon(forFile: mp) }
        if let p = v.iconPath {
            if let img = cache[p] { return img }
            if let img = NSImage(contentsOfFile: p) {
                cache[p] = img
                return img
            }
        }
        if v.isInternal { return internalDisk ?? external }
        return v.isEjectable ? (removable ?? external) : external
    }

    /// Line-art glyph for the sidebar and the menu bar list.
    static func symbol(for v: Volume) -> String {
        v.isInternal || v.isRootVolume ? "internaldrive" : "externaldrive"
    }
}

/// Monochrome drive glyph used in lists (as in Paragon's sidebar).
struct DriveGlyph: View {
    var volume: Volume
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: DriveIcons.symbol(for: volume))
            .font(.system(size: size * 0.82, weight: .light))
            .frame(width: size, height: size)
            .foregroundStyle(.white.opacity(volume.isMounted ? 0.95 : 0.45))
    }
}

struct DriveIcon: View {
    var volume: Volume
    var size: CGFloat
    var showBadge = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let img = DriveIcons.image(for: volume) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .frame(width: size * 0.8, height: size * 0.8)
                    .frame(width: size, height: size)
            }
            // NTFS disks show their own icon, like in Finder and Paragon.
            if showBadge && !volume.isNTFS {
                FSBadge(volume: volume)
                    .offset(x: size * 0.08, y: -size * 0.04)
            }
        }
        .opacity(volume.isMounted ? 1 : 0.55)
    }
}

/// Ribbon-like label shown on the big drive icon ("NTFS", "macOS", ...).
struct FSBadge: View {
    var volume: Volume

    var text: String {
        if volume.isNTFS { return "NTFS" }
        if let os = volume.operatingSystem, os.hasPrefix("macOS") { return "macOS" }
        if volume.operatingSystem == "Windows" { return "Windows" }
        return volume.fileSystemName
    }

    var color: Color {
        if volume.isNTFS { return Theme.badgeNTFS }
        if text == "macOS" { return Theme.badgeMac }
        return Theme.badgeOther
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                UnevenRoundedCorners(radius: 9)
                    .fill(color)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            )
    }
}

/// Rounded on the leading corners and the bottom trailing corner, like a tag.
struct UnevenRoundedCorners: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Small badges in the sidebar

struct TagBadge: View {
    var text: String
    var foreground: Color
    var background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(background))
    }
}

struct StatusDot: View {
    var status: Volume.Status
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
    var color: Color {
        switch status {
        case .readWrite: return Theme.statusRW
        case .readOnly: return Theme.statusRO
        case .unmounted: return Theme.statusOff
        }
    }
}

// MARK: - Toolbar button (icon above label)

struct ToolbarAction: View {
    var title: String
    var systemImage: String
    var tint: Color
    var enabled: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(enabled ? tint : Color.secondary)
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
            }
            .frame(minWidth: 54)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .help(title)
    }
}

// MARK: - Usage bar

struct UsageSegment: Identifiable {
    var id: String { name }
    var name: String
    var bytes: Int64
    var color: Color
}

struct UsageBar: View {
    var total: Int64
    var free: Int64
    var segments: [UsageSegment]

    var used: Int64 { max(0, total - free) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(format: NSLocalizedString("%@ Total", comment: ""), Format.size(total)))
                Spacer()
                Text(String(format: NSLocalizedString("%@ Used", comment: ""), Format.size(used)))
                Spacer()
                Text(String(format: NSLocalizedString("%@ Free", comment: ""), Format.size(free)))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(segments) { s in
                        Rectangle()
                            .fill(s.color)
                            .frame(width: total > 0 ? geo.size.width * CGFloat(Double(s.bytes) / Double(total)) : 0)
                    }
                    Spacer(minLength: 0)
                }
                .background(Theme.barTrack)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 12)

            HStack(alignment: .top, spacing: 22) {
                ForEach(segments.filter { $0.bytes > 0 }) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.system(size: 11.5, weight: .semibold))
                            Text(Format.size(s.bytes)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Info card row

struct InfoRow<Value: View>: View {
    var label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 12)
            value()
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Spinner overlay text

struct BusyLabel: View {
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
