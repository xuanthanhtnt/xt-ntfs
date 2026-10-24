#!/usr/bin/env python3
"""In ghi chú phát hành trên GitHub cho một phiên bản, lấy từ CHANGELOG.md."""
import os
import re
import sys

version = sys.argv[1]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
text = open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8").read()
m = re.search(rf"^## \[?{re.escape(version)}\]?.*?$(.*?)(?=^## |\Z)", text, re.S | re.M)
body = m.group(1).strip() if m else "Xem CHANGELOG.md."

print(f"""{body}

### Cài đặt
1. Cài [macFUSE](https://macfuse.github.io/) và cho phép system extension của nó (máy chip Apple: bật kernel extension trong Startup Security Utility, giống yêu cầu của Paragon NTFS). Từ macOS 26 có thể bỏ qua bước này: bật macFUSE trong Cài đặt hệ thống → Cài đặt chung → Mục đăng nhập & Tiện ích mở rộng → Tiện ích hệ thống tệp, XT NTFS sẽ dùng backend FSKit.
2. Mở file DMG và kéo **XT NTFS** vào thư mục Applications.
3. App chưa được Apple notarize: lần đầu mở, nhấp chuột phải vào app → **Mở**, hoặc vào Cài đặt hệ thống → Quyền riêng tư & Bảo mật → **Vẫn mở**.
4. Trong XT NTFS, bấm **XT NTFS** ở cuối thanh bên → **Cài engine…**.

Các bản cập nhật sau được tải ngay trong app (Sparkle, có chữ ký EdDSA).
""")
