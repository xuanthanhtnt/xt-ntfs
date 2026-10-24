# Nhật ký thay đổi

## [1.0.0] - 2026-10-24

Bản phát hành đầu tiên.

- Đọc/ghi ổ NTFS trên macOS 13 Ventura đến macOS 27, chip Apple và Intel (bản universal).
- Giao diện kiểu Paragon: thanh bên liệt kê ổ kèm trạng thái, nhãn read-only/nobrowse và nút tháo ổ; các nút Mount/Unmount, Kiểm tra, Xoá và Khởi động; thông tin ổ, thanh dung lượng chia theo loại file; tuỳ chọn riêng từng ổ (Spotlight, chỉ đọc, không tự động mount).
- Tự động mount đọc/ghi: một dịch vụ nền (LaunchDaemon) chặn lần mount chỉ đọc của macOS với ổ NTFS và mount ổ bằng engine XT ngay khi cắm vào.
- Engine XT: ntfs-3g 2026.9.28 kèm lớp đọc/ghi thiết bị raw mới (truyền khối lớn, thẳng hàng sector qua `/dev/rdisk`, bộ đệm ghi sau cho metadata, luồng ghi nền) và các tuỳ chọn macFUSE đã tinh chỉnh. Ba chế độ hiệu năng: Tương thích, Cân bằng, Turbo.
- Xử lý ổ có Windows ngủ đông (Fast Startup) và ổ chưa tháo an toàn theo tuỳ chọn: kiểm tra trước, mount chỉ đọc, hoặc xoá dữ liệu ngủ đông.
- Kiểm tra / sửa lỗi (ntfsfix), xoá và định dạng lại sang NTFS, ExFAT, FAT32, APFS hoặc Mac OS Extended, đổi tên ổ.
- Công cụ đo tốc độ (ghi/đọc tuần tự bỏ qua bộ nhớ đệm, file nhỏ) có lưu lịch sử, để so sánh các driver trên cùng một ổ.
- Menu trên thanh menu, thông báo, giao diện sáng/tối, tiếng Việt và tiếng Anh.
- Tự cập nhật trong app qua Sparkle 2, bản phát hành có chữ ký EdDSA.
- Chọn backend macFUSE: kernel extension (nhanh nhất) hoặc FSKit (không cần kernel extension, macOS 15.4+ với macFUSE 5). Ở chế độ Tự động, nếu không nạp được kernel extension thì trên macOS 26 trở lên sẽ chuyển sang FSKit.
