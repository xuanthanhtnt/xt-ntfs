# Nhật ký thay đổi

## [1.2.1] - 2026-10-28

- **Chỉ chạy trên menu bar khi khởi động:** XT NTFS không tự mở cửa sổ chính hoặc xuất hiện trên Dock; chọn **Mở XT NTFS** vẫn mở cửa sổ ứng dụng.
- **Mở Cài đặt từ menu bar:** mục **Cài đặt…** mở thẳng cửa sổ Cài đặt, không mở cửa sổ chính.

## [1.2.0] - 2026-10-25

- **Biểu tượng ổ trong Finder và trên desktop:** ổ mount bằng XT NTFS giờ hiện đúng biểu tượng macOS dùng cho ổ đó (ví dụ ổ USB màu vàng), giống Paragon, thay vì biểu tượng "FUSE" mặc định của macFUSE. Nguyên nhân cũ: macFUSE chỉ nạp mô-đun biểu tượng ổ khi chương trình dùng `fuse_main()`, còn ntfs-3g mount theo cách khác nên tuỳ chọn `volicon` bị bỏ qua. Engine giờ tự nạp mô-đun này; nếu vì lý do nào đó mount kèm biểu tượng thất bại, dịch vụ nền tự mount lại không kèm biểu tượng.
- **Biểu tượng ổ trong app:** ảnh lớn của ổ dùng biểu tượng thật của macOS (ổ USB, ổ trong…) thay cho hình hộp "NTFS"; thanh bên dùng nét vẽ ổ đĩa đơn sắc như Paragon. Ổ đang mount hiện rõ, ổ chưa mount mờ đi.
- **Menu bar kiểu Paragon:** bấm biểu tượng trên menu bar mở một bảng liệt kê từng ổ NTFS với biểu tượng, tên, dung lượng trống, kiểu kết nối (ví dụ USB 3 · 5 Gb/s), thanh dung lượng, trạng thái và nút Mount / Unmount / Tháo ổ; nút bánh răng để mở app, cài đặt, kiểm tra cập nhật và thoát.
- **Thoát app:** khi bật biểu tượng menu bar, chọn Quit trong menu app, trên Dock hoặc ⌘Q chỉ đóng cửa sổ và biểu tượng Dock; XT NTFS vẫn chạy trên menu bar. Chỉ "Thoát XT NTFS" trong bảng menu bar mới thoát hẳn (cập nhật app, đăng xuất và tắt máy vẫn thoát bình thường). Mở lại app từ Launchpad/Spotlight hoặc chọn "Mở XT NTFS" trong menu bar để hiện lại cửa sổ.

## [1.1.1] - 2026-10-25

- Engine không khởi động luồng nền (ghi nền, đọc trước) trong lúc mount nữa: macFUSE chạy trình mount bằng `fork()`, và tách tiến trình khi đã có nhiều luồng là không an toàn (log engine 1.1.0 có dòng "fuse: forking a threaded process is unsafe"). Các luồng giờ chỉ bắt đầu sau khi macFUSE báo đã mount xong.
- Đọc trước chỉ bật sau khi đã đọc tuần tự ít nhất 1 MB, để các lần đọc lẻ không làm tốn băng thông ổ.
- README: bảng đo thực tế trên ổ SSD USB 3 so với Paragon NTFS.

## [1.1.0] - 2026-10-24

Tăng tốc engine, dựa trên số đo thực tế so với Paragon NTFS trên ổ SSD USB 3.

- **Đọc trước (read-ahead):** khi một file được đọc tuần tự, engine tải sẵn các đoạn tiếp theo bằng luồng nền trong lúc app đang nhận đoạn hiện tại, nên ổ không còn đứng chờ giữa các yêu cầu của macFUSE. Chế độ Cân bằng đọc trước 4 MB (2 luồng), Turbo 16 MB (3 luồng).
- **Ghi không cần đọc trước:** trước đây mỗi lần ghi vào vùng chưa có trong bộ đệm, engine phải đọc cả khối 256 KB quanh đó từ ổ rồi mới ghi. Với file mới (ntfs-3g đặt mỗi file ở một vùng trống khác nhau), nghĩa là mỗi file nhỏ tốn thêm một lần đọc ổ. Giờ các lần ghi thẳng hàng sector ghi thẳng vào bộ đệm, không đọc gì từ ổ. Trong thử nghiệm mô phỏng độ trễ USB, tạo file nhỏ nhanh gấp khoảng 3 lần và ghi tuần tự nhanh gấp khoảng 1,8 lần.
- Engine ghi thống kê kích thước yêu cầu đọc/ghi vào `/Library/Logs/XTNTFS-<ổ>.log` khi tháo ổ, để tối ưu tiếp dựa trên số liệu thật.
- Sửa lỗi ổ mới cắm vào hiện biểu đồ dung lượng của ổ cũ khi macOS cấp lại cùng tên thiết bị (ví dụ `disk7s2`).
- Kiểm thử: bài stress ngẫu nhiên có thêm các luồng đọc tuần tự xen với ghi ngay phía trước (chạy dưới ASan/UBSan và ThreadSanitizer), và bài kiểm tra FUSE đầu-cuối đối chiếu với ntfs-3g gốc.

## [1.0.4] - 2026-10-24

- Sửa lỗi không tháo được ổ ngay sau khi mở app: app tự quét dung lượng theo loại file và giữ ổ trong lúc quét. Giờ việc quét được dừng trước khi tháo, đẩy ra, kiểm tra, xoá, đổi tên hay đo tốc độ, rồi tự chạy lại sau đó.

## [1.0.3] - 2026-10-24

- Khi không tháo được ổ vì đang có ứng dụng dùng, app nêu tên các ứng dụng đó và cho phép **Ép tháo** / **Ép đẩy ra** (giống Disk Utility). Trước khi báo lỗi, engine tự thử tháo lại vài lần vì Spotlight, Quick Look hay Finder thường chỉ giữ ổ trong chốc lát.
- Hiện tốc độ cổng USB của ổ (ví dụ "USB 2.0 · 480 Mb/s") trong thông tin ổ, kèm cảnh báo khi ổ chạy ở tốc độ USB 2.0 (tối đa khoảng 40 MB/s với mọi driver).

## [1.0.2] - 2026-10-24

- Sửa lỗi mount với macFUSE: bỏ tuỳ chọn `defer_permissions` vì ntfs-3g đã tự dùng `default_permissions` khi gán quyền sở hữu, và macFUSE từ chối khi có cả hai.
- Hiện nguyên văn lỗi của macFUSE khi mount thất bại.
- Sửa lỗi app bỏ sót thông báo sau khi engine khởi động lại (số thứ tự sự kiện không còn đếm lại từ 1).

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
