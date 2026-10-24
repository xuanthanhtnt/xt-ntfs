# Nhật ký thay đổi

## [1.0.1] - 2026-10-24

Sửa lỗi phát hiện khi cài thử trên máy Mac M1 chạy macOS 27 với macFUSE 5.5.

- Sửa lỗi ổ không mount được với macFUSE 5: ntfs-3g tự tách nền bằng `fork()` sau khi mở kênh FUSE, trong khi macFUSE 5 hoàn tất mount qua XPC nên mount bị bỏ dở. Engine giờ luôn chạy ở chế độ foreground dưới dịch vụ nền.
- Phát hiện đúng khi macOS chặn engine đọc ổ (quyền riêng tư "Ổ đĩa di động" / Truy cập toàn bộ ổ đĩa) thay vì báo nhầm "Windows đang ngủ đông"; app hiện thẻ hướng dẫn cấp quyền cho dịch vụ nền kèm nút mở thẳng trang cài đặt.
- Không tháo ổ khỏi driver khác (macOS, Paragon…) khi engine không đọc được ổ; nếu mount bằng XT thất bại thì tự trả ổ về cho driver trước đó.
- Thêm nút **Khởi động lại engine**.
- Thêm tuỳ chọn **Lưu thời gian truy cập** cho từng ổ NTFS (giống Paragon); mặc định tắt để nhanh hơn.
- Báo rõ khi kernel extension của macFUSE chưa được nạp (cần cho phép và khởi động lại máy).

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
