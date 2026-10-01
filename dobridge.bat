@echo off
setlocal
cd /d "%~dp0"

rem === Find Visual Studio (any version) with C++ tools via vswhere ===
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSINSTALL="
if exist "%VSWHERE%" for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSINSTALL=%%i"
if not defined VSINSTALL (
  echo [ERROR] Visual Studio with C++ tools not found via vswhere.
  echo Edit this file and call vcvars64.bat manually, see BUILD-DNUDesk.md.
  exit /b 1
)
call "%VSINSTALL%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1

rem === vcpkg: vcvars overwrites VCPKG_ROOT, so reset it AFTER vcvars ===
if exist "E:\dev\vcpkg\bootstrap-vcpkg.bat" set "VCPKG_ROOT=E:\dev\vcpkg"
if not exist "%VCPKG_ROOT%\bootstrap-vcpkg.bat" (
  echo [ERROR] vcpkg not found at VCPKG_ROOT=%VCPKG_ROOT%
  echo Set it globally: setx VCPKG_ROOT "path\to\vcpkg"  or edit this file.
  exit /b 1
)
set "CARGO_TARGET_DIR="

where flutter_rust_bridge_codegen >nul 2>&1 || cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked
where cargo-expand >nul 2>&1 || cargo install cargo-expand --version 1.0.95 --locked

flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h
