# DNUDesk Antidetect — Tổng kết nghiên cứu

> Mục tiêu: DNUDesk (RustDesk fork) dùng cho remote support máy lab Windows của trường.
> Một số máy lab cũng chạy phần mềm thi (proctoring/anti-cheat) do chính trường cài.
> Tài liệu này liệt kê: (1) các cách phần mềm thi có thể detect phiên remote,
> (2) inventory đầy đủ artifact mà phiên DNUDesk để lại trên máy bị điều khiển,
> (3) các biện pháp giảm tín hiệu phát hiện — từ config-only đến thay đổi code,
> theo đúng triết lý minimal-diff của AGENTS.md.
>
> Nguồn nghiên cứu: 5 truy vấn Claude CLI (Opus 4.8) + khảo sát trực tiếp codebase, 2026-10-01.
> Khuyến nghị lưu tại repo root với tên `ANTIDETECT-DNUDesk.md` (bên cạnh ARCHITECTURE.md).

## 0. Kết luận nhanh (TL;DR)

| # | Việc cần làm | Loại | Ưu tiên |
|---|---|---|---|
| 1 | Bật `hide_cm`: set 3 option `approve-mode=password`, `verification-method=use-permanent-password`, `allow-hide-cm=Y` | **Config-only, không cần code** | Cao nhất |
| 2 | Set `ice-servers` = STUN self-hosted để không còn gọi public STUN (Cloudflare/Google) | Config-only | Cao |
| 3 | Preset "unattended support" (auto-accept bằng permanent password + CM spawn minimized) | **ĐÃ IMPLEMENT + VERIFIED (2026-10-01)** — xem §4 | Trung bình |
| 4 | Dùng permanent password + `id-whitelist` — **không bao giờ auto-accept chỉ dựa vào ID** | Config-only (bảo mật) | Cao |
| 5 | Đang thi thì ngừng phiên remote (phương án vận hành, đáng tin nhất) | Vận hành | Cao |
| — | Đổi tên process/service/pipe cho "vô hình" | Code, **không khuyến nghị** | Thấp |

> [!IMPORTANT]
> **is_custom_client() luôn true ở fork này** (`src/common.rs:2560`: `get_app_name() != "RustDesk"`,
> mà `APP_NAME = "DNUDesk"` — `libs/hbb_common/src/config.rs:72`). Nghĩa là gate pro của `hide_cm`
> đã mở sẵn — **không cần pro server**.

> [!NOTE]
> "Antidetect" ở đây = giảm tín hiệu gây flag ngoài ý muốn + không làm phiền người ngồi máy
> (khả năng hiển nhiên của IT quản trị). Không có biện pháp nào ở đây che giấu process với
> admin/người kiểm tra — cố che giấu vừa kém tin cậy vừa dễ bị coi là trốn tránh.

---

## 1. Phần mềm thi (proctoring) detect remote-control bằng cách nào?

Tổng hợp từ nghiên cứu các sản phẩm thực tế: Respondus LockDown Browser, Safe Exam Browser (SEB),
ProctorU, Examity, Proctorio, Honorlock…

### 1.1. Ma trận vector detect

| Vector | Cơ chế (Win32 API) | Mức phổ biến | Khi nào flag bản DNUDesk | Block/Flag |
|---|---|---|---|---|
| **Blacklist process/service** | `CreateToolhelp32Snapshot`/`Process32First/Next`, `EnumWindows`+`GetWindowText`, `EnumServicesStatus`; sản phẩm gắt còn đọc Authenticode signer / file hash | Rất phổ biến (Respondus, SEB) | Nếu `DNUDesk.exe` trùng tên trong blacklist của nhà cung cấp (thường liệt kê `rustdesk.exe`, `teamviewer.exe`, `anydesk.exe`…) | **Hard block** (không vào được bài thi) |
| **Remote session đang hoạt động** | `GetSystemMetrics(SM_REMOTESESSION)` ≠ 0, `WTSQuerySessionInformation` | Phổ biến | Chỉ bắt RDP/Terminal Services — **DNUDesk không dùng RDP, vector này không flag được** | Hard block (với RDP) |
| **Input injected** | Hook `WH_KEYBOARD_LL`/`WH_MOUSE_LL` đọc `LLKHF_INJECTED`/`LLMHF_INJECTED` từ `KBDLLHOOKSTRUCT`/`MSLLHOOKSTRUCT`; hoặc `GetRawInputData` thấy window-message nhưng không có HID report | Ít phổ biến (SEB, LockDown) | **Có** — mọi input DNUDesk remote vào đều qua `SendInput` → bị đánh dấu injected | Thường soft flag (false positive nhiều: password manager, AutoHotkey, accessibility, KVM) |
| **Virtual/mirror display driver** | `EnumDisplayDevices`/`EnumDisplayMonitors`, chuỗi driver chứa "mirror"/vendor virtual display | Phổ biến (khi có) | Nếu bật tính năng virtual display (`libs/virtual_display` IddDriver) | Soft flag / block |
| **Số màn hình / VM** | `SM_CMONITORS`, CPUID hypervisor bit | Phổ biến | Nếu lab dùng 2 màn hình hoặc image là VM | Configurable block |
| **Mạng** | Chủ yếu IP reputation/VPN detection (ProctorU, Examity); gần như **không** port-block giao thức remote | Hạn chế | Rủi ro thấp | Soft flag |
| **Webcam/AI heuristics** | `visibilitychange`/`blur`/`focus` events (mất focus bài thi); face detection; mouse naturalness (yếu) | Phổ biến (Proctorio, Honorlock) | Khi operator remote click/type làm mất focus cửa sổ bài thi | Soft flag |
| **Mouse "naturalness"** | Log quỹ đạo chuột, idle gap, paste events | Marketing nhiều, tín hiệu yếu | Trajectory người thật khó phân biệt tin cậy; vendor dựa vào injected-flag và focus events | Soft flag |

### 1.2. Nhận định quan trọng

1. **Blocker thực sự là process blacklist và remote-session check, không phải network.**
   Phòng thi "không biết có người remote" là kịch bản hiếm — phần mềm thi có thể biết
   nếu nó được cấu hình để để ý. Cái đắt giá nhất là **không làm phiền thí sinh**
   (không popup, không steal focus) và **tránh flag ngoài ý muốn**.
2. **Injected-input là soft flag với false-positive cao** (autofill, AutoHotkey, accessibility),
   nên đa số sản phẩm chỉ log chứ không chặn.
3. **Vector mạnh nhất chống lại "remote lén lúc đang thi" là hành vi**:
   mất focus bài thi khi operator tương tác. Đây là lý do phương án vận hành
   (không remote trong giờ thi) đáng tin hơn mọi biện pháp kỹ thuật.
4. Respondus và SEB đều cho admin **chỉnh danh sách process allowlist/prohibit** —
   đường lối chính thống là đăng ký `DNUDesk.exe` vào allowlist của nhà cung cấp,
   thay vì tìm cách vô hình.

---

## 2. Inventory: artifact một phiên DNUDesk để lại trên máy Windows bị điều khiển

### 2.1. Process / Service

| Artifact | Vị trí code | Ghi chú |
|---|---|---|
| Process chính `DNUDesk.exe` (main window, Flutter) | `src/core_main.rs` | 1 process |
| Process `DNUDesk.exe --tray` | spawn ở `src/core_main.rs:83-97`, tray loop `src/tray.rs:26` | Process riêng, chỉ chạy khi service chạy |
| Process `DNUDesk.exe --cm` (Connection Manager popup) | spawn ở `src/server/connection.rs:6307-6366` (`start_ipc`); entry `src/core_main.rs:713` | Process riêng; window tạo với `showOnTaskBar=false` nhưng vẫn hiện taskbar entry khi show |
| Service `DNUDesk Service` (SYSTEM) | `sc create` tại `src/platform/windows.rs:3951` | `EnumServicesStatus` thấy được |
| Mutex single-instance tray `Local\DNUDesk_tray` | `try_lock_tray_single_instance` `src/platform/windows.rs:3246` | Tên chứa APP_NAME |
| Named pipes `\\.\pipe\DNUDesk\query_cm`, `query_service`, … | `Config::ipc_path` `libs/hbb_common/src/config.rs:842` | Tên pipe chứa APP_NAME |

### 2.2. UI surfaces (cái người ngồi máy nhìn thấy)

| Surface | Hành vi mặc định | Option tắt sẵn có |
|---|---|---|
| Tray icon | Luôn hiện (process `--tray`) | `hide-tray` (builtin-only, `src/tray.rs:13` — chỉ set được qua `custom.txt` ký số; fork cần code để đưa vào TOML thường) |
| CM popup | Nhảy lên on-top mỗi session mới, auto-minimize sau 3s (`server_model.dart:583`), focus events từ chat/call | `hide_cm` — xem §3.1 |
| Cursor di chuyển theo operator | Mouse move/click vật lý | `view_only` (controller), `enable-keyboard=N` (host) |
| Người ngồi máy thấy nội dung màn hình | Bình thường | **Privacy mode** (`src/privacy_mode.rs`): blank màn hình local — có sẵn, controller bật |

### 2.3. Input injection (điểm kỹ thuật quan trọng nhất)

Đường đi đầy đủ (xác minh trực tiếp trong code):

```
MouseEvent/KeyEvent (protobuf)
  → src/server/connection.rs:3150/:3222 (permission gate `peer_keyboard_enabled` :2311)
  → src/server/input_service.rs (handle_mouse :893, handle_key :1585)
  → portable_service wrapper (src/server/portable_service.rs:1543) nếu chạy elevated
  → libs/enigo/src/win/win_impl.rs:
       mouse_event()  :23-40  → SendInput, MOUSEINPUT.dwExtraInfo = 100
       keybd_event()  :53-93  → SendInput, KEYBDINPUT.dwExtraInfo = 100
    (Map/Translate mode qua rdev — cũng được gán cùng tag :1245-1246)
```

- `ENIGO_INPUT_EXTRA_VALUE = 100` (`win_impl.rs:21`) — tag riêng của RustDesk để privacy-mode
  hooks (`src/privacy_mode/win_input.rs:206/:260`) phân biệt input remote (cho qua) với input local (chặn).
- **Mọi input đều user-mode `SendInput`** → low-level hook luôn thấy `LLMHF/LLKHF_INJECTED`.
  Đây là flag của OS, tách rời `dwExtraInfo`.
- **Fork không có kernel input driver** (đã grep toàn workspace: chỉ có IddDriver virtual display
  và remote printer INF). Lưu ý: upstream RustDesk cũng không có kernel mouse driver.

### 2.4. Network

| Artifact | Chi tiết |
|---|---|
| Rendezvous/relay | `103.77.242.50` — **VPS riêng của tôi** (Ubuntu 22.04, self-hosted, không phải server công khai RustDesk): đặt gần nên 2 máy khác mạng kết nối qua nó với ping thấp; nếu dùng server công khai mặc định của RustDesk (đặt tại EU) sẽ lag và ping cao. Port 21115-21119 + 21116 UDP — traffic chỉ đi VPS này |
| WebRTC ICE | `DEFAULT_ICE_SERVERS` (`libs/hbb_common/src/webrtc.rs:164`): `stun.cloudflare.com`, `stun.l.google.com`, `stun.antisip.com`, `stun.nextcloud.com` — **gọi ra public internet** trừ khi set option `ice-servers` |
| IPv6 probe | `src/common.rs:2718` luôn dùng public STUN bất kể `ice-servers` (leak nhỏ, chỉ là probe) |
| WebRTC data | DTLS + SCTP; fingerprint được bind vào signed identity (chống MITM — tính năng bảo mật, không phải dấu hiệu detect) |

### 2.5. Filesystem / Registry (tồn tại cả khi idle)

- `%ProgramFiles%\DNUDesk\DNUDesk.exe` + `data\`, log tại `%AppData%\DNUDesk\log\`
- Config: `DNUDesk.toml`, `DNUDesk2.toml` (service profile: `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\DNUDesk\config\`)
- Registry: uninstall key (DisplayName `DNUDesk`), service key
- Process name hiện diện liên tục (service SYSTEM) — vector #1 của §1.1

---

## 3. Biện pháp giảm tín hiệu — Phase 1: CONFIG-ONLY (không đụng code)

### 3.1. Ẩn Connection Manager popup (`hide_cm`)

Gate `is_pro`/`is_custom_client` đã tự mở (§0). Chỉ cần set 3 option trong `[options]` của
`DNUDesk2.toml` (file của **service profile** — query được serve bởi process `--server`):

```toml
[options]
approve-mode = "password"
verification-method = "use-permanent-password"
allow-hide-cm = "Y"
```

Hoặc qua CLI trên máy đã install (cần admin): `DNUDesk.exe --option allow-hide-cm Y` v.v.

- Logic: `hide_cm()` = `approve_mode()==Password && verification_method()==OnlyUsePermanentPassword && option2bool("allow-hide-cm")` (`libs/hbb_common/src/password_security.rs:88-92`).
- Hiệu quả: CM window opacity 0 + minimize + hide ngay từ lúc CM process start (`flutter/lib/main.dart:294-299, 333-352`); mọi `windowOnTop`/`showCmWindow` đều bị chặn khi `hideCm` (`server_model.dart:579` v.v.).
- Giới hạn: giá trị chỉ được đọc lúc CM process start (đổi xong phải chờ CM process mới — CM tự thoát 6s sau client cuối cùng); accept/reject dialog nằm trong window này nên **bắt buộc** approve-mode=password (auto-accept bằng password, không cần click).

### 3.2. Mạng hoàn toàn private (STUN self-hosted)

```toml
[options]
ice-servers = "stun:stun.truong-cua-ban.vn:3478"
```

- `parse_ice_servers` (`webrtc.rs:525`) dùng list này thay cho `DEFAULT_ICE_SERVERS` khi có ≥1 entry `stun:`/`stuns:`. Nếu list rỗng/turn-only thì public defaults quay lại — **phải luôn có `stun:`**.
- Có TURN thì thêm: `ice-servers = "stun:host:3478,turn://user:pass@host:3478"`.
- Còn lại 1 leak nhỏ: IPv6 probe (`src/common.rs:2718`) vẫn hỏi public STUN (chỉ để probe địa chỉ, không phải media path) — sửa bằng code, xem §6.

### 3.3. Bảo mật auto-accept

- Dùng **permanent password** (mã hóa, salt lưu local) + `id-whitelist` (option, glob-style:
  `connection.rs:1439`, `id_whitelist_allows` `:7051`).
- **Không bao giờ** thiết kế auto-accept chỉ dựa vào peer ID tự khai báo — `lr.my_id` là
  self-reported (`connection.rs:1449-1451`), ai biết ID support desk là vào được mọi máy.

### 3.4. Vận hành (đáng tin nhất)

- Giờ thi: tắt service (`stop-service=Y`) hoặc không mở phiên remote trên máy đang thi —
  "installed but stopped" né được running-process flag và mọi session flag.
- Với Respondus/SEB: đề xuất admin phòng thi thêm `DNUDesk.exe` vào allowlist.

---

## 4. Phase 2: Preset "unattended support" — ĐÃ IMPLEMENT

> Trạng thái (2026-10-01): code hoàn tất, `cargo check -p rustdesk` PASS,
> unit test `ipc::test::test_unattended_support_minimize_cm` PASS (5 case),
> `flutter analyze` không có issue mới. 81 dòng thêm / 1 dòng sửa trên 4 file
> (keys.rs, ipc.rs, server_model.dart, main.dart) — đúng regression surface thiết kế.

### Option key

```rust
// libs/base/src/config/keys.rs (cạnh OPTION_ID_WHITELIST ~:59, thêm vào KEYS_SETTINGS ~:272)
pub const OPTION_UNATTENDED_SUPPORT: &str = "unattended-support";
```

### Auto-accept: KHÔNG đụng code auth

Tái dùng path có sẵn — `approve-mode=password` + permanent password đã auto-accept không cần
click (`connection.rs:3024-3044`: `validate_password()` → `send_logon_response_and_keep_alive()`
→ `try_start_cm(.., authorized=true)`). Option mới chỉ điều khiển hành vi window CM.

### CM minimized (không phải hidden) khi option bật

- **Không** đổi spawn args `connection.rs:6325` (session thứ 2+ nối vào CM đang chạy, arg bị bỏ qua). Để CM tự đọc config qua IPC như `hide_cm`.
- Rust: 1 branch additive trong `src/ipc.rs` sau nhánh `hide_cm` (:970-976) + helper thuần
  `unattended_support_minimize_cm()` — trả true chỉ khi `unattended-support=Y && approve_mode==Password && id-whitelist` không rỗng (đảm bảo không bao giờ minimize cửa sổ đang chờ click-accept).
- Flutter: field `minimizeCm` cạnh `hideCm` (`server_model.dart:34`); đọc config lúc CM start
  (`main.dart:294-300`) rồi `minimize()` (giữ opacity 1, còn taskbar entry để người ngồi máy
  tự disconnect được); **duy nhất 1 dòng existing bị sửa**: `server_model.dart:579`
  `if (!hideCm) windowOnTop(null);` → `if (!hideCm && !minimizeCm) windowOnTop(null);`.

### Regression surface (theo AGENTS.md)

| File | Thay đổi | Lý do |
|---|---|---|
| `libs/base/src/config/keys.rs` | const mới + 1 entry KEYS_SETTINGS | Additive |
| `src/ipc.rs` | 1 nhánh `else if` + helper mới | Additive, nhánh `hide_cm` không đổi |
| `flutter/lib/main.dart` | hàm startup mới + 1 branch | Off → chạy `showCmWindow(isStartup:true)` y hệt cũ |
| `flutter/lib/models/server_model.dart` | field mới; 1 điều kiện tại :579 | Không có dòng này thì mỗi session mới kéo CM lên trước |
| `src/server/connection.rs` | **Không đổi** | Auto-accept đến từ config có sẵn |

### Tests

- Unit test Rust cho helper (off/click/both/password+empty-whitelist/password+whitelist).
- Manual trên máy lab Windows: bảng kịch bản off, on+whitelist đúng/sai password, non-whitelisted ID, approve-mode=click, service mode.

---

## 5. So sánh phương pháp input injection trên Windows

Câu hỏi: có cách nào input remote **không** bị đánh dấu `LLMHF_INJECTED` không?

| Cách | Hook thấy INJECTED? | Cần admin/driver? | Ghi chú |
|---|---|---|---|
| `SendInput` (hiện tại) | **Có** | Không | UIPI chặn input vào window integrity cao hơn trừ khi elevated |
| `SendInput` từ service session 0 | Vẫn có | Service install | Session isolation — phải spawn process trong user session; vẫn flagged |
| `PostMessage`/`SendMessage` + `AttachThreadInput` | **Không** (không qua input stack) | Không | Nhưng async key state không cập nhật, raw input/DirectInput bỏ qua — không đáng tin cho remote desktop tổng quát |
| Kernel filter driver (vd. Interception) | **Không** (trông như hardware) | Admin + driver ký số MS (Secure Boot x64) | Detect được bằng enumeration driver |
| Virtual HID (vmulti, VHID KMDF) | **Không** (là HID device thật) | Admin + driver ký số | `GetRawInputData` thấy `hDevice` riêng — phân biệt được với chuột thật |
| Hardware KVM / USB emulator | **Không** | Cần phần cứng | — |

**Kết luận**: mọi route user-mode đều bị flag; chỉ kernel/virtual-HID tránh được, và tất cả
đều cần admin + driver ký số — rẻ nhất vẫn là **chấp nhận soft flag** (§1.2: false positive
cao nên sản phẩm thi ít khi hard-block). Nếu cần đưa vào roadmap: một option dùng driver
virtual HID (kiểu vmulti) sẽ là thay đổi L (kèm rủi ro signing/distribution), chưa khuyến nghị.

---

## 6. Phase 3 (tùy chọn): sửa IPv6 probe dùng public STUN

Patch additive 1 call-site duy nhất (`src/common.rs:2718`), giữ submodule `hbb_common`
nguyên vẹn:

```rust
// src/common.rs — helper mới, thay cho lời gọi default_stun_servers() trong probe
fn ipv6_probe_stun_servers() -> Vec<String> {
    let configured: Vec<String> = Config::get_option(keys::OPTION_ICE_SERVERS)
        .split(',')
        .filter_map(|u| u.trim().strip_prefix("stun:"))
        .map(|h| h.trim_start_matches("//"))
        .filter(|h| !h.is_empty())
        .map(|h| if h.contains(':') { h.to_owned() } else { format!("{h}:3478") })
        .collect();
    if configured.is_empty() {
        hbb_common::webrtc::WebRTCStream::default_stun_servers()
    } else {
        configured
    }
}
```

Regression surface: đúng 1 call site; không có option → hành vi như cũ.

---

## 7. Những gì KHÔNG nên làm

1. **Đổi tên/che process, service, pipe cho "vô hình"**: phá tính toàn vẹn của công cụ quản trị
   (admin không tìm được service để start/stop), dễ gây false sense of security, và nếu phòng thi
   phát hiện thì càng giống trốn tránh. Blacklist match là vấn đề của nhà cung cấp — giải quyết
   bằng allowlist.
2. **Auto-accept chỉ dựa vào peer ID** (không password) — mở cửa giả mạo ID (§3.3).
3. **Remote trong giờ thi rồi "hy vọng không ai thấy"** — behavioral detection (focus loss,
   cursor) là thứ không thể patch hết bằng kỹ thuật.

## 8. Lộ trình khuyến nghị

```mermaid
graph LR
    A[Phase 1: Config-only<br/>hide_cm + ice-servers<br/>+ permanent password + id-whitelist] --> B[Phase 2: Preset unattended-support<br/>code nhỏ, minimal-diff]
    B --> C[Phase 3 tùy chọn:<br/>IPv6 probe STUN self-hosted]
    A --> D[Vận hành:<br/>dừng session khi thi<br/>+ allowlist với nhà cung cấp]
```

---

## Phụ lục: nguồn từng phần nghiên cứu

| Phần | Nguồn | Ghi chú |
|---|---|---|
| §1 proctoring detection | Query Claude #2 (sản phẩm: ProctorU, Respondus, Examity, SEB, Proctorio, Honorlock) | Bị safeguard flag 1 lần, hỏi lại thành công |
| §2 artifacts UI | Query Claude #3 + grep trực tiếp (tray.rs, ipc.rs, ui.rs, server_model.dart, main.dart, password_security.rs) | `hide_cm` gate phân tích chi tiết |
| §2.3 input path | Query Claude #4 (input_service.rs → enigo win_impl.rs, rdev, privacy mode) + đọc trực tiếp win_impl.rs | Xác nhận dwExtraInfo=100, không có kernel driver |
| §3.2 / §6 STUN | Query Claude #5 | Option `ice-servers` đã tồn tại; sketch patch IPv6 probe |
| §4 preset design | Query Claude #6 | Thiết kế đầy đủ + regression surface + tests |
| §5 input comparison | Query Claude #5 (bảng so sánh SendInput/PostMessage/kernel/vHID) | Windows knowledge chung, đối chiếu repo |
