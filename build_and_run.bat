@echo off
setlocal EnableExtensions

rem Usage: build_and_run.bat [--compile-shaders] [--no-run]
rem
rem Overridable environment variables:
rem   ODIN_ROOT    Odin install directory      (default: %USERPROFILE%\opt\Odin)
rem   MSYS2_UCRT64 MSYS2 UCRT64 bin directory  (default: C:\msys64\ucrt64\bin)

set "ROOT=%~dp0"
cd /d "%ROOT%" || exit /b 1

if not defined ODIN_ROOT set "ODIN_ROOT=%USERPROFILE%\opt\Odin"
if not defined MSYS2_UCRT64 set "MSYS2_UCRT64=C:\msys64\ucrt64\bin"

set "ODIN=%ODIN_ROOT%\odin.exe"
if not exist "%ODIN%" (
    echo [ERROR] odin.exe not found at "%ODIN%". Set ODIN_ROOT.
    exit /b 1
)

set "COMPILE_SHADERS=0"
set "RUN=1"
:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--compile-shaders" set "COMPILE_SHADERS=1"
if /i "%~1"=="--no-run" set "RUN=0"
shift
goto :parse_args
:args_done

if "%COMPILE_SHADERS%"=="1" (
    call "%ROOT%shaders\compile.bat" || exit /b 1
)

rem libgit2 is linked through a GNU import archive (libgit2.dll.a), which the
rem default RAD linker cannot handle, so LLD is required.
"%ODIN%" build ./src -debug -linker:lld -out:Git-Workbench.exe || exit /b 1

if "%RUN%"=="0" exit /b 0

rem Runtime DLLs: SDL3.dll ships with Odin, libgit2.dll is built in vendor/,
rem and libgit2's dependencies (OpenSSL, libssh2, pcre2, zlib) come from MSYS2.
if not exist "%MSYS2_UCRT64%\libssh2-1.dll" (
    echo [WARN] libgit2 dependencies not found in "%MSYS2_UCRT64%". Set MSYS2_UCRT64.
)
set "PATH=%ROOT%vendor\libgit2\build-ucrt64;%ODIN_ROOT%\vendor\sdl3;%MSYS2_UCRT64%;%PATH%"

"%ROOT%Git-Workbench.exe"
