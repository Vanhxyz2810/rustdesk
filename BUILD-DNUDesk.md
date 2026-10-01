# Hướng dẫn build DNUDesk (Windows)

> Bản build đã chạy thành công trên: Windows 11, Visual Studio 2026 (v18), rustc 1.98, toolchain đặt ở ổ `E:`.
> DNUDesk = bản rebrand của RustDesk. Tài liệu này ghi lại đúng các bước + những lỗi đã gặp và cách xử lý.

---

## 1. Yêu cầu công cụ (đúng version)

| Công cụ | Version | Ghi chú |
|---|---|---|
| Visual Studio | 2026 Community (v18) | Cần workload **Desktop development with C++** (MSVC + Windows SDK) |
| Rust (rustup) | stable (đã dùng 1.98) | target `x86_64-pc-windows-msvc` |
| Flutter | **3.24.5** | Pin đúng bản này (CI dùng), đừng lên bản mới |
| LLVM / libclang | **15.0.6** | bindgen cần `libclang.dll` |
| vcpkg | baseline `9e593bb18ea69cc5095e012465dcd675a822ed0d` | **full clone**, không shallow |
| Python | 3.10+ | chạy `build.py`, `generate.py` |
| NASM, Ninja, CMake, Git | mới nhất | NASM cho libvpx/aom |
| flutter_rust_bridge_codegen | **1.80.1** | sinh FFI, cài bằng `cargo install` |
| cargo-expand | **1.0.95** | frb codegen cần |

---

## 2. Đưa toolchain sang ổ khác C: (nếu C: ít dung lượng)

Đặt biến môi trường (User scope), rồi **mở terminal/VS Code mới**:

```
CARGO_HOME    = E:\dev\cargo
RUSTUP_HOME   = E:\dev\rustup
VCPKG_ROOT    = E:\dev\vcpkg
PUB_CACHE     = E:\dev\pub-cache
LIBCLANG_PATH = E:\dev\LLVM\bin
```

⚠️ **KHÔNG set `CARGO_TARGET_DIR`.** `build.py` và `flutter/windows/CMakeLists.txt` hardcode đường dẫn `target/release`, nếu đổi hướng sẽ không tìm thấy `librustdesk.dll` → build hỏng.

Thêm vào PATH: `E:\dev\cargo\bin`, `E:\dev\flutter\bin`, `E:\dev\LLVM\bin`, thư mục NASM.

---

## 3. Submodule + vcpkg

```bash
# Trong thư mục repo
git submodule update --init --recursive     # libs/hbb_common (bắt buộc)

# vcpkg — PHẢI full clone (overrides ffnvcodec/amd-amf cần lịch sử git)
git clone https://github.com/microsoft/vcpkg E:\dev\vcpkg
cd E:\dev\vcpkg
git checkout 9e593bb18ea69cc5095e012465dcd675a822ed0d
.\bootstrap-vcpkg.bat -disableMetrics

# Cài thư viện C/C++ (chạy ở thư mục repo có vcpkg.json)
cd <repo>
set VCPKG_DEFAULT_HOST_TRIPLET=x64-windows-static
%VCPKG_ROOT%\vcpkg install --triplet x64-windows-static --x-install-root=%VCPKG_ROOT%\installed
```

> Nếu lỡ clone vcpkg shallow: `git fetch --unshallow origin` rồi cài lại.
> Bước này build ffmpeg + libvpx + aom + libyuv + opus từ source (~9 phút trên máy mạnh).

---

## 4. Sinh FFI (flutter_rust_bridge) — repo KHÔNG commit sẵn

Repo không có `src/bridge_generated.rs` — phải sinh trước khi build, nếu không lỗi `file not found for module bridge_generated`.

Tạo file `dobridge.bat`:

```bat
@echo off
call "E:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
set "VCPKG_ROOT=E:\dev\vcpkg"
set "CARGO_TARGET_DIR="
cd /d <repo>
cargo install cargo-expand --version 1.0.95 --locked
cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked
flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h
```

Chạy 1 lần (và mỗi khi sửa `src/flutter_ffi.rs`).

---

## 5. Vá Flutter cho Visual Studio 2026

Flutter 3.24.5 chưa biết VS 2026 (v18) → chọn nhầm CMake generator "Visual Studio 16 2019" → lỗi *"could not find any instance of Visual Studio"*.

Sửa file `<flutter>\packages\flutter_tools\lib\src\windows\visual_studio.dart`, hàm `cmakeGenerator`, thêm dòng `18`:

```dart
return switch (_majorVersion) {
  18 => 'Visual Studio 18 2026',   // <-- thêm dòng này
  17 => 'Visual Studio 17 2022',
  _  => 'Visual Studio 16 2019',
};
```

Sau khi sửa, xoá snapshot để Flutter biên dịch lại tool:

```bash
del <flutter>\bin\cache\flutter_tools.snapshot
del <flutter>\bin\cache\flutter_tools.stamp
```

> Nếu đổi generator mà báo *"does not match the generator used previously"* → xoá `flutter\build\windows` (CMakeCache cũ).

---

## 6. Build app

Tạo file `dobuild.bat`:

```bat
@echo off
call "E:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
set "VCPKG_ROOT=E:\dev\vcpkg"
set "CARGO_TARGET_DIR="
cd /d <repo>
python build.py --portable --flutter --skip-portable-pack --hwcodec
```

**Vì sao phải qua vcvars64.bat + set lại VCPKG_ROOT:**
- `vcvars64.bat` set biến `INCLUDE` — bindgen/libclang cần nó, không có sẽ lỗi `'stdlib.h' file not found`.
- vcvars **ghi đè** `VCPKG_ROOT` sang vcpkg bundled của VS (rỗng) → phải set lại. Dùng dạng có ngoặc kép `set "VCPKG_ROOT=..."` (dạng không ngoặc `set X=.. &&` bị dính dấu cách thừa vào giá trị → sai đường dẫn).

Kết quả: `flutter\build\windows\x64\runner\Release\` gồm `DNUDesk.exe` + `librustdesk.dll` (~39MB) + plugin DLL + `data\`. Chép cả thư mục đi đâu cũng chạy (portable, tự chứa, không cần VC++ redist).

---

## 7. Đóng gói installer 1 file

Tạo file `dopack.bat`:

```bat
@echo off
call "E:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
set "VCPKG_ROOT=E:\dev\vcpkg"
set "CARGO_TARGET_DIR="
cd /d <repo>
python -m pip install -r libs/portable/requirements.txt
cd /d <repo>\libs\portable
python generate.py -f ../../flutter/build/windows/x64/runner/Release -o . -e ../../flutter/build/windows/x64/runner/Release/DNUDesk.exe
```

> `build.py` hardcode `rustdesk.exe` nên phải gọi thẳng `generate.py` với `-e DNUDesk.exe` (tên đã rebrand).

Kết quả: `target\release\rustdesk-portable-packer.exe` (~24MB). Đổi tên thành `DNUDesk-<version>-install.exe` để phát hành.

---

## 8. Các chỗ đã tùy biến (rebrand + server)

Rebrand RustDesk **được điều khiển bởi 1 công tắc chính: `APP_NAME`**. Đổi nó là mọi thứ (tên exe, đường dẫn cài, service, shortcut, tiêu đề cửa sổ, chuỗi UI) tự khớp theo.

| Mục | File | Sửa |
|---|---|---|
| Tên app (công tắc chính) | `libs/hbb_common/src/config.rs` | `APP_NAME = "DNUDesk"` |
| Tên binary flutter | `flutter/windows/CMakeLists.txt` | `BINARY_NAME "DNUDesk"` |
| Task Manager (FileDescription) | `flutter/windows/runner/Runner.rc` | `FileDescription = "DNUDesk"` |
| Version-info exe Rust | `Cargo.toml` | `description` + `[package.metadata.winres] FileDescription` |
| **Server tự host** | `libs/hbb_common/src/config.rs` (dòng ~117-118) | `RENDEZVOUS_SERVERS = &["<IP_VPS>"]` và `RS_PUB_KEY = "<key>"` |

> ⚠️ `APP_NAME` **phải khớp** `BINARY_NAME`. Nếu chỉ đổi 1 trong 2, bản cài sẽ hỏng (shortcut/service trỏ sai tên exe → app không tự mở).

Sau khi sửa bất kỳ file `.rs`/`.rc`/`Cargo.toml` nào → chạy lại `dobuild.bat` + `dopack.bat`.

---

## 9. Server tự host (giảm độ trễ khi khác mạng)

Dựng relay gần → độ trễ 539ms → ~51ms. Trên VPS (Ubuntu + Docker):

```yaml
# /root/rustdesk/docker-compose.yml
services:
  hbbs:
    image: rustdesk/rustdesk-server:latest
    command: hbbs -r <IP_VPS>:21117
    volumes: [./data:/root]
    network_mode: "host"
    restart: unless-stopped
  hbbr:
    image: rustdesk/rustdesk-server:latest
    command: hbbr
    volumes: [./data:/root]
    network_mode: "host"
    restart: unless-stopped
```

```bash
cd /root/rustdesk && docker compose up -d
cat /root/rustdesk/data/id_ed25519.pub    # <-- public key, nhét vào RS_PUB_KEY
```

Mở firewall/security group: **21115/TCP, 21116/TCP+UDP, 21117/TCP** (quên UDP 21116 là lỗi hay gặp nhất).
Cả 2 máy phải cài bản DNUDesk đã nhúng server thì mới thấy nhau qua server đó.

---

## 10. Bảng lỗi thường gặp → cách sửa

| Lỗi | Nguyên nhân | Sửa |
|---|---|---|
| `'stdlib.h' file not found` (kcp-sys/scrap) | Thiếu `INCLUDE` | Build trong `vcvars64.bat` |
| `vpx/vp8.h` / `opus_multistream.h` not found | `VCPKG_ROOT` sai (VS ghi đè, hoặc dính dấu cách) | `set "VCPKG_ROOT=E:\dev\vcpkg"` sau vcvars |
| `file not found for module bridge_generated` | Chưa sinh FFI | Chạy `dobridge.bat` |
| `could not find any instance of Visual Studio` (CMake) | Flutter chưa biết VS 2026 | Vá `visual_studio.dart` (mục 5) |
| `failed to unpack tree object` (vcpkg) | vcpkg shallow clone | `git fetch --unshallow` |
| Cài xong app không tự mở / shortcut hỏng | `APP_NAME` ≠ `BINARY_NAME` | Đặt cả 2 = "DNUDesk", rebuild |

---

## 11. Tóm tắt lệnh (khi đã setup xong)

```bash
# Sửa code xong:
dobridge.bat     # chỉ khi đổi src/flutter_ffi.rs
dobuild.bat      # build -> DNUDesk.exe + librustdesk.dll
dopack.bat       # đóng gói -> installer 1 file
```
