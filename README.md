<p align="center"><img src="docs/assets/icon-256.png" width="128" alt="XT NTFS"></p>

<h1 align="center">XT NTFS</h1>

<p align="center">Ghi dữ liệu vào ổ NTFS trên Mac, giao diện quen thuộc như Paragon NTFS.</p>

<p align="center">
  <a href="https://github.com/xuanthanhtnt/xt-ntfs/releases/latest/download/XT-NTFS.dmg">Tải bản mới nhất (DMG)</a> ·
  <a href="https://xuanthanhtnt.github.io/xt-ntfs/">Trang giới thiệu</a> ·
  <a href="CHANGELOG.md">Nhật ký thay đổi</a>
</p>

---

## XT NTFS làm được gì

Cắm ổ cứng, SSD hay USB định dạng trên Windows vào Mac là ổ được mount ở chế độ **đọc/ghi** trong Finder, không cần thao tác gì thêm. App quản lý ổ theo kiểu một tiện ích ổ đĩa:

- Thanh bên liệt kê các ổ, có chấm trạng thái (đọc/ghi, chỉ đọc), nhãn `read-only` / `nobrowse` và nút tháo ổ
- **Mount / Unmount**, **Kiểm tra** (và sửa lỗi), **Xoá** (định dạng lại sang NTFS, ExFAT, FAT32, APFS, Mac OS Extended), **Khởi động**, đổi tên ổ
- Thông tin ổ: thiết bị, hệ thống tệp, driver, hệ điều hành, thanh dung lượng chia theo loại file
- Tuỳ chọn riêng từng ổ: bật lập chỉ mục Spotlight, mount chỉ đọc, không tự động mount
- Xử lý ổ có Windows đang ngủ đông (Fast Startup) và ổ chưa được tháo an toàn
- Ba chế độ hiệu năng (Tương thích, Cân bằng, Turbo) và công cụ **đo tốc độ** có lưu lịch sử
- Chạy trên thanh menu, không hiện trên Dock khi khởi động; mục **Mở XT NTFS** mở cửa sổ chính và **Cài đặt…** mở thẳng cửa sổ cài đặt
- Thông báo, giao diện sáng/tối, tiếng Việt và tiếng Anh
- Tự cập nhật ngay trong app (Sparkle 2, bản phát hành có chữ ký EdDSA)

## Yêu cầu

- macOS 13 Ventura trở lên, chip Apple hoặc Intel
- [macFUSE](https://macfuse.github.io/), đã cho phép system extension. Máy chip Apple cần bật kernel extension trong Startup Security Utility, giống yêu cầu của các driver NTFS thương mại có kernel extension.
- Từ macOS 26 có thể bỏ qua kernel extension: bật macFUSE trong Cài đặt hệ thống → Cài đặt chung → Mục đăng nhập & Tiện ích mở rộng → Tiện ích hệ thống tệp, XT NTFS sẽ mount qua backend FSKit của macFUSE (chậm hơn kernel extension). Có thể chọn backend trong Cài đặt → Chung (Tự động / Kernel extension / FSKit).

## Cài đặt

1. Cài macFUSE.
2. Tải file DMG ở mục [Releases](https://github.com/xuanthanhtnt/xt-ntfs/releases/latest) rồi kéo **XT NTFS** vào thư mục Applications.
3. App chỉ được ký ad-hoc, chưa được Apple notarize: lần đầu mở, nhấp chuột phải vào app → **Mở**, hoặc vào Cài đặt hệ thống → Quyền riêng tư & Bảo mật → **Vẫn mở**.
4. Bấm **XT NTFS** ở cuối thanh bên → **Cài engine…** và nhập mật khẩu quản trị.

Nếu máy đang cài Paragon NTFS, chỉ nên bật một driver: khi driver XT NTFS bật, nó sẽ nhận mount ổ NTFS trước.

## Cách hoạt động

```
 ┌───────────────┐   socket (JSON)   ┌──────────────────────────┐
 │ XT NTFS.app   │ ────────────────▶ │ xtntfsd (LaunchDaemon)   │
 │ SwiftUI       │                   │ theo dõi DiskArbitration │
 └───────────────┘                   │  - chặn mount chỉ đọc    │
                                     │    của macOS với ổ NTFS  │
                                     │  - mount/kiểm tra/xoá    │
                                     └────────────┬─────────────┘
                                                  │ khởi chạy
                                     ┌────────────▼─────────────┐
                                     │ ntfs-3g + XT raw I/O     │──▶ /dev/rdiskXsY
                                     │ trên macFUSE (kext/FSKit)│
                                     └──────────────────────────┘
```

- **Dịch vụ nền** (`Sources/xtntfsd`): đăng ký callback duyệt mount của DiskArbitration, nhờ đó macOS (hay driver khác) không mount ổ NTFS ở chế độ chỉ đọc trước, mà dịch vụ sẽ mount ổ bằng engine XT. Dịch vụ cũng thực hiện kiểm tra, sửa lỗi, xoá, đổi tên, bật/tắt Spotlight và báo sự kiện cho app.
- **Engine** (`engine/`): [ntfs-3g](https://github.com/tuxera/ntfs-3g) gốc cộng thêm `xt_rawio.c`, một lớp đọc/ghi thiết bị:
  - dùng thiết bị raw (`/dev/rdisk…`) thay cho thiết bị block, tránh việc kernel chia mọi thao tác thành khối nhỏ vài KB,
  - giữ mọi yêu cầu đọc/ghi thẳng hàng theo sector (đọc-sửa-ghi ở hai đầu, dùng bộ đệm căn lề),
  - đẩy các yêu cầu lớn thẳng xuống ổ, còn các lần ghi nhỏ vào MFT, chỉ mục và bitmap được gom trong bộ đệm ghi sau rồi một luồng nền ghi theo thứ tự trên đĩa (khi `fsync`, khi unmount và trước `fork()`).
- **Backend FSKit**: mount qua FSKit phải do người dùng đang đăng nhập thực hiện và không qua được `fork()`, nên dịch vụ tạm giao thiết bị raw cho người dùng đó trong lúc mount và chạy ntfs-3g ở chế độ foreground trong phiên của họ (`launchctl asuser`).
- **Tuỳ chọn macFUSE** theo chế độ hiệu năng: `iosize` lớn (1 MiB / 8 MiB), `noatime`, `negative_vncache`, `noappledouble`, thuộc tính mở rộng lưu thành stream NTFS.

### Kiểm thử

- `engine/tests/rawio_stress.c` (chạy trên Linux trong CI): đọc/ghi/seek/sync/fork ngẫu nhiên so với ảnh tham chiếu trong bộ nhớ, sector 512 và 4096, bộ đệm rất nhỏ để ép thay thế dòng cache, O_DIRECT, AddressSanitizer, UndefinedBehaviorSanitizer và ThreadSanitizer.
- `engine/tests/e2e_linux.sh`: định dạng một ảnh đĩa, mount qua FUSE bằng engine XT, chép hàng nghìn file (cả tên tiếng Việt, tiếng Nhật, emoji), đổi tên, xoá, ghi đè, cắt ngắn, rồi kiểm tra bằng `ntfsfix` và đọc lại từng file bằng ntfs-3g gốc.
- `scripts/ci-integration.sh` (chạy trên máy macOS của CI): cài dịch vụ nền, gửi lệnh qua socket, định dạng / kiểm tra / đổi tên / xoá một ổ NTFS trên RAM disk và đo tốc độ engine.

Kết quả đo được trong CI:

| Phép thử | Cách thông thường | Engine XT |
|---|---|---|
| Chép 3.000 file nhỏ (Linux, FUSE) | 7,21 s (tắt bộ đệm XT) | 1,25 s |
| Ghi file 512 MB lên RAM disk (macOS, không qua FUSE) | 134 MB/s qua `/dev/disk` | 287 MB/s qua `/dev/rdisk` |

Đo thực tế trên máy thật (MacBook Air M1, macOS 27, macFUSE 5.5 kernel extension), bằng công cụ đo trong app (ghi/đọc tuần tự bỏ qua bộ nhớ đệm, tạo 500 file 4 KB rồi fsync), cùng một ổ, xen kẽ hai driver:

**Ổ SSD 128 GB qua USB 3 (5 Gb/s)**, file thử 256 MB đến 4 GB, mỗi driver 5–8 lần đo:

| Driver | Ghi tuần tự | Đọc tuần tự | File nhỏ (4 KB) |
|---|---|---|---|
| Paragon NTFS 17 | 139–166 MB/s | 225–227 MB/s | 783–889 file/s ¹ |
| XT NTFS 1.0.4 – Cân bằng | 139 MB/s | 204–205 MB/s | 391–408 file/s |
| **XT NTFS 1.1 – Cân bằng** | 138–186 MB/s | 224–228 MB/s | **1.466–2.359 file/s** |

¹ Hai lần đo 4 GB ngay sau một loạt ghi lớn, Paragon chỉ đạt 379–388 file/s.

Với ổ này, ghi và đọc tuần tự của cả hai driver đều chạm giới hạn của chính ổ (khoảng 140–150 MB/s ghi, 226 MB/s đọc). Tạo file nhỏ XT NTFS 1.1 nhanh hơn Paragon khoảng 1,6–2,8 lần. Hai thay đổi trong engine 1.1 làm nên khác biệt so với 1.0.4: đọc trước khi đọc tuần tự (đọc +11%), và ghi file mới không cần đọc trước vùng xung quanh từ ổ (file nhỏ gấp 3,6–6 lần).

**Ổ HDD 500 GB qua USB 2.0**, file thử 1 GB, trung bình 2 lần đo (bản 1.0.2): Paragon 37,4 / 37,9 MB/s, 204 file/s; XT NTFS 37,9 / 38,5 MB/s, 117 file/s. Ở USB 2.0 cả hai driver đều kẹt ở khoảng 38–40 MB/s. Dòng **Kết nối** trong thông tin ổ (từ bản 1.0.3) cho biết ngay ổ đang chạy USB 2.0 hay USB 3 và cảnh báo khi dây hoặc cổng làm chậm ổ.

Tốc độ thực tế phụ thuộc vào ổ và cổng kết nối; hãy dùng tính năng đo tốc độ trong app để so sánh các driver trên chính máy của bạn.

## Build

```sh
# engine (macOS): cần autoconf automake libtool pkgconf libgcrypt (Homebrew)
engine/fetch-macfuse-sdk.sh /tmp/macfuse
MACFUSE_PREFIX=/tmp/macfuse engine/build-ntfs3g.sh build/engine

# app + DMG
scripts/build-app.sh build/engine/bin build
scripts/make-dmg.sh "build/XT NTFS.app" build/XT-NTFS.dmg
```

GitHub Actions (`.github/workflows/build.yml`) chạy kiểm thử engine, build engine và app (universal) ở mỗi lần push, phát hành bản mới kèm DMG và `appcast.xml` có chữ ký mỗi khi `VERSION` đổi, và đưa trang giới thiệu trong `docs/` lên nhánh `gh-pages`.

### Phát hành bản mới

1. Thêm khoá riêng EdDSA của Sparkle (dạng base64) vào secret của repo tên `SPARKLE_ED_PRIVATE_KEY` (Settings → Secrets and variables → Actions). Khoá công khai tương ứng nằm ở `Resources/sparkle_public_key.txt`.
2. Tăng số trong `VERSION`, thêm mục mới vào `CHANGELOG.md` rồi push lên `main`. Khi CI thấy phiên bản mới chưa có bản phát hành, nó sẽ build DMG, tạo tag `vX.Y.Z`, tạo bản phát hành và đính kèm `appcast.xml` đã ký. (Push tag `vX.Y.Z` cũng được.)

Nếu chưa có secret, bản phát hành vẫn được tạo nhưng không được đẩy tới người dùng qua tự cập nhật. Khi đó có thể ký thủ công: tải DMG về, chạy `SPARKLE_ED_PRIVATE_KEY=… scripts/make-appcast.py <dmg> <phiên bản> <số build> <url> dist/appcast.xml` rồi commit `dist/appcast.xml`; CI sẽ kiểm tra chữ ký với DMG đã phát hành rồi đính kèm vào bản phát hành.

### Ký app bằng chứng chỉ cố định (khuyến nghị)

Mặc định app được ký ad-hoc, nên mỗi bản build có "dấu vân tay" khác nhau và macOS coi dịch vụ nền là chương trình mới: sau mỗi lần cập nhật engine phải bật lại quyền **Truy cập toàn bộ ổ đĩa** cho `com.xuanthanhtnt.xtntfs.helper`. Ký bằng một chứng chỉ cố định (tự tạo cũng được) giúp quyền này được giữ qua các bản cập nhật:

1. Tạo chứng chỉ ký code tự ký (ví dụ bằng OpenSSL, `extendedKeyUsage=codeSigning`, CN tuỳ ý) và xuất ra file `.p12` có mật khẩu (`openssl pkcs12 -export -legacy …`).
2. Thêm hai secret cho repo: `XT_CODESIGN_P12` (nội dung file `.p12` dạng base64) và `XT_CODESIGN_PASSWORD`.

CI sẽ nạp chứng chỉ bằng `scripts/setup-signing.sh` và ký app, engine, dịch vụ nền bằng nó. Lần đầu chuyển từ ad-hoc sang chứng chỉ vẫn cần bật lại quyền một lần; từ đó trở đi thì không cần nữa. Chứng chỉ Developer ID của Apple còn tốt hơn: app được notarize và không bị Gatekeeper cảnh báo.

## Lưu ý

- Luôn tháo (Eject) ổ NTFS trước khi rút ra.
- Kiểm tra/sửa lỗi dùng `ntfsfix`: sửa được các lỗi thường gặp và yêu cầu Windows chạy `chkdsk` đầy đủ ở lần cắm tiếp theo.
- Chưa hỗ trợ ổ mã hoá BitLocker.
- Không liên quan tới Microsoft hay Paragon Software. NTFS là thương hiệu của Microsoft Corporation.

## Giấy phép

GPL-2.0-or-later (xem [LICENSE](LICENSE)). Có kèm ntfs-3g (GPL-2.0-or-later / LGPL-2.0-or-later, © Tuxera và cộng đồng). Không đóng gói kèm macFUSE.

---

*English:* XT NTFS mounts Windows NTFS drives read-write on macOS (ntfs-3g with a raw-device I/O layer on macFUSE), with a Paragon-style volume manager, benchmark and in-app updates. Requires macOS 13+ and macFUSE. Download the DMG from [Releases](https://github.com/xuanthanhtnt/xt-ntfs/releases/latest).
