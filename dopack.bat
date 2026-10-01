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

python -m pip show requests >nul 2>&1 || python -m pip install -r libs/portable/requirements.txt

pushd libs\portable
python generate.py -f ../../flutter/build/windows/x64/runner/Release -o . -e ../../flutter/build/windows/x64/runner/Release/DNUDesk.exe
popd

if exist "target\release\rustdesk-portable-packer.exe" (
  echo.
  echo === OK: installer ready ===
  ren target\release\rustdesk-portable-packer.exe DNUDesk-install.exe
  echo target\release\DNUDesk-install.exe
  echo Upload: scp target\release\DNUDesk-install.exe root@103.77.242.50:/var/www/html/dl/
) else (
  echo [ERROR] rustdesk-portable-packer.exe not found - build may have failed
  exit /b 1
)
