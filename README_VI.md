<p align="center">
  <img src="assets/icon-256.png" alt="WinDebloat Live" width="128">
</p>

<h1 align="center">WinDebloat Live</h1>

<p align="center">
  Gỡ ứng dụng thừa và tối ưu trực tiếp máy Windows 10 / 11 đang sử dụng, an toàn và có thể hoàn tác.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/PowerShell-5.1-5391FE.svg?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/Windows-10%201809%2B%20%7C%2011-0078D6.svg" alt="Windows 10 1809+ | 11">
</p>

<p align="center">
  <a href="README.md">English</a> · Tiếng Việt
</p>

---

## Giới thiệu
WinDebloat Live gỡ các ứng dụng cài sẵn và tắt quảng cáo, gợi ý, Copilot cùng cơ chế tự cài ứng dụng ngay trên
máy Windows 10 hoặc Windows 11 đang chạy. Công cụ đi kèm WinDebloat Tool (vốn áp dụng các quy tắc này vào bộ cài)
và dùng chung danh sách ứng dụng và tinh chỉnh. Chế độ **Đơn giản** dọn dẹp máy bằng một nút bấm theo mặc định an
toàn; chế độ **Nâng cao** cho phép chọn từng ứng dụng, từng thiết lập và xem trước chính xác các thay đổi. Giao
diện theo chế độ sáng/tối của Windows, hiển thị sắc nét trên màn hình DPI cao, có tiếng Việt và tiếng Anh,
một phần tiếng Trung và tiếng Khmer.

## Điểm nổi bật
- Gỡ ứng dụng cài sẵn cho mọi người dùng (kể cả tài khoản tạo sau) hoặc chỉ cho người dùng đang đăng nhập.
- Tinh chỉnh registry cho máy, cho người dùng đang đăng nhập và tuỳ chọn cho hồ sơ Default của tài khoản mới.
- Chỉ hiển thị quy tắc phù hợp với phiên bản và build đang chạy; quy tắc chỉ dành cho bộ cài được bỏ qua kèm lý do.
- Xem trước mọi thay đổi trước khi áp dụng, ghi log chi tiết và hỏi khởi động lại khi hoàn tất.
- Danh sách quy tắc trong [`data/`](data) tự cập nhật ở chế độ nền, xác minh bằng SHA256 (có thể tắt).

## Bắt đầu nhanh
1. Chuột phải file zip → **Properties** → tích **Unblock**, sau đó giải nén.
2. Nhấp đúp **`run.bat`** và đồng ý cấp quyền Administrator.
3. Chọn **Đơn giản** rồi bấm **Tối ưu máy này**, hoặc chọn **Nâng cao**, đánh dấu các mục rồi bấm **Áp dụng**.
4. Khởi động lại máy khi được hỏi.

Ví dụ dòng lệnh (chạy trong PowerShell quyền Administrator):

```powershell
.\WinDebloatLive.ps1 -NoGui -Preview                    # chỉ xem trước, không thay đổi gì
.\WinDebloatLive.ps1 -NoGui -Preset aggressive          # chạy trong console, có xác nhận
.\WinDebloatLive.ps1 -NoGui -Yes -EnableSystemProtection -Restart
.\WinDebloatLive.ps1 -ListBackups
.\WinDebloatLive.ps1 -Undo latest
```

## Yêu cầu
- Windows 10 phiên bản 1809 (build 17763) trở lên hoặc Windows 11; chỉ bản dành cho máy trạm.
- Windows PowerShell 5.1 (có sẵn trong Windows). Không cần PowerShell 7; công cụ tự chạy lại bằng bản 5.1.
- Quyền Administrator (`run.bat` tự yêu cầu).

## An toàn
- Điểm khôi phục hệ thống được tạo trước. Bảo vệ hệ thống (System Protection) chỉ được bật khi người dùng đồng ý.
- Mọi giá trị registry, kiểu khởi động dịch vụ và ứng dụng đã gỡ đều được ghi vào file sao lưu JSON trong
  `%ProgramData%\WinDebloatLive\backups`; nút **Hoàn tác** khôi phục lại. Chỉ quản trị viên được ghi vào thư mục này.
- Các thành phần cốt lõi không bao giờ bị gỡ: Microsoft Store, App Installer, các framework, Windows Security, Edge
  và WebView2, Start và các gói giao diện hệ thống, Photos, Calculator, Notepad và codec đa phương tiện. Windows
  Terminal chỉ bị gỡ khi được chọn rõ ràng trong chế độ Nâng cao.
- Mỗi mục được áp dụng riêng: mục bị từ chối quyền truy cập hoặc gặp lỗi được ghi log và bỏ qua, các mục khác vẫn tiếp tục.
- Ứng dụng đã gỡ có thể cài lại từ Microsoft Store nếu file của ứng dụng không còn trên máy.

Nên thử trên máy ảo hoặc sau khi đã có điểm khôi phục trước khi dùng trên máy quan trọng.

## Credits
- WinDebloat Tool: danh sách ứng dụng và tinh chỉnh dùng chung, định dạng quy tắc và cơ chế cập nhật.
- [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat) (MIT): danh sách ứng dụng và mức độ an toàn.
- [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) và
  [farag2/Sophia-Script-for-Windows](https://github.com/farag2/Sophia-Script-for-Windows) (MIT): các tinh chỉnh quyền riêng tư.

Windows, DISM và System Restore là sản phẩm của Microsoft. Không có thành phần nào của Microsoft được phân phối lại tại đây.

## Giấy phép
[MIT](LICENSE)
