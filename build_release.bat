@echo off
setlocal EnableExtensions

rem Builds an optimized, console-less release and packages it as a portable
rem folder (dist\Git-Workbench) plus a zip (dist\Git-Workbench.zip).
rem
rem Usage: build_release.bat [--compile-shaders]
rem
rem Overridable environment variables:
rem   ODIN_ROOT    Odin install directory      (default: %USERPROFILE%\opt\Odin)
rem   MSYS2_UCRT64 MSYS2 UCRT64 bin directory  (default: C:\msys64\ucrt64\bin)
rem
rem Fonts and shaders are embedded in the exe. gitaris.json is still read and
rem written in the working directory.

set "ROOT=%~dp0"
cd /d "%ROOT%" || exit /b 1

if not defined ODIN_ROOT set "ODIN_ROOT=%USERPROFILE%\opt\Odin"
if not defined MSYS2_UCRT64 set "MSYS2_UCRT64=C:\msys64\ucrt64\bin"

set "ODIN=%ODIN_ROOT%\odin.exe"
if not exist "%ODIN%" (
    echo [ERROR] odin.exe not found at "%ODIN%". Set ODIN_ROOT.
    exit /b 1
)

if /i "%~1"=="--compile-shaders" (
    call "%ROOT%shaders\compile.bat" || exit /b 1
)

set "DIST=%ROOT%dist"
set "OUT=%DIST%\Git-Workbench"
set "ZIP=%DIST%\Git-Workbench.zip"

if exist "%OUT%" rmdir /s /q "%OUT%" || exit /b 1
if exist "%ZIP%" del /q "%ZIP%" || exit /b 1
mkdir "%OUT%" || exit /b 1

echo Building release...
rem LLD is required for libgit2's GNU import archive (see build_and_run.bat).
"%ODIN%" build ./src -o:speed -subsystem:windows -linker:lld -out:"%OUT%\Git-Workbench.exe" || exit /b 1
if exist "%OUT%\Git-Workbench.pdb" del /q "%OUT%\Git-Workbench.pdb"

echo Copying runtime DLLs...
call :copy_file "%ODIN_ROOT%\vendor\sdl3\SDL3.dll" "%OUT%" || exit /b 1
call :copy_file "%ROOT%vendor\libgit2\build-ucrt64\libgit2.dll" "%OUT%" || exit /b 1
for %%D in (
    libssh2-1.dll
    libssl-3-x64.dll
    libcrypto-3-x64.dll
    libpcre2-8-0.dll
    zlib1.dll
) do (
    call :copy_file "%MSYS2_UCRT64%\%%D" "%OUT%" || exit /b 1
)

echo Copying licenses...
rem Fonts are embedded in the exe (#load); only their licenses ship alongside.
call :copy_as "%ROOT%LICENSE" "%OUT%\LICENSE" || exit /b 1
call :copy_as "%ROOT%assets\fonts\Satoshi_Complete\Satoshi_Complete\License\FFL.txt" "%OUT%\licenses\Satoshi-FFL.txt" || exit /b 1
call :copy_as "%ROOT%assets\fonts\Gambarino_Complete\License\FFL.txt" "%OUT%\licenses\Gambarino-FFL.txt" || exit /b 1

echo Creating zip...
tar -a -c -f "%ZIP%" -C "%DIST%" Git-Workbench || exit /b 1

echo.
echo Release folder: %OUT%
echo Release zip:    %ZIP%
exit /b 0

rem copy_file <source> <destination directory>
:copy_file
if not exist "%~1" (
    echo [ERROR] Missing "%~1"
    exit /b 1
)
if not exist "%~f2" mkdir "%~f2" || exit /b 1
copy /y "%~1" "%~f2" >nul || exit /b 1
exit /b 0

rem copy_as <source> <destination file>
:copy_as
if not exist "%~1" (
    echo [ERROR] Missing "%~1"
    exit /b 1
)
if not exist "%~dp2" mkdir "%~dp2" || exit /b 1
copy /y "%~1" "%~f2" >nul || exit /b 1
exit /b 0
