import SwiftUI
import XTShared

struct EraseSheet: View {
    @EnvironmentObject var model: AppModel
    var volume: Volume
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var format: EraseFormat = .ntfs
    @State private var confirmText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                DriveIcon(volume: volume, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: NSLocalizedString("Erase “%@”?", comment: ""), volume.name))
                        .font(.system(size: 15, weight: .semibold))
                    Text(NSLocalizedString("Erasing deletes all data stored on this volume. This cannot be undone.", comment: ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Form {
                TextField(NSLocalizedString("Name:", comment: ""), text: $name)
                Picker(NSLocalizedString("Format:", comment: ""), selection: $format) {
                    Text("Microsoft NTFS").tag(EraseFormat.ntfs)
                    Text("ExFAT").tag(EraseFormat.exfat)
                    Text("MS-DOS (FAT32)").tag(EraseFormat.fat32)
                    Text("Mac OS Extended (Journaled)").tag(EraseFormat.hfsplus)
                    Text("APFS").tag(EraseFormat.apfs)
                }
            }
            .formStyle(.columns)
            Text(NSLocalizedString("Type ERASE to confirm.", comment: ""))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("ERASE", text: $confirmText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Erase", comment: ""), role: .destructive) {
                    isPresented = false
                    let n = name, f = format
                    Task { await model.erase(volume, format: f, label: n) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(confirmText != "ERASE" || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear {
            name = volume.name
            format = volume.isNTFS ? .ntfs : .exfat
        }
    }
}

struct ReportSheet: View {
    @EnvironmentObject var model: AppModel
    var report: ReportItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: report.failed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(report.failed ? Theme.statusRO : Theme.verifyGreen)
                Text(report.title).font(.system(size: 15, weight: .semibold))
            }
            ScrollView {
                Text(report.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
            HStack {
                if report.canRepair {
                    Text(NSLocalizedString("XT NTFS can fix common problems. For a full check, run chkdsk on Windows.", comment: ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if report.canRepair, let v = model.volumes.first(where: { $0.bsdName == report.bsdName }) {
                    Button(NSLocalizedString("Repair", comment: "")) {
                        model.report = nil
                        Task { await model.verify(v, repair: true) }
                    }
                }
                Button(NSLocalizedString("Done", comment: "")) { model.report = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
