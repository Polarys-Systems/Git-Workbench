@echo off
setlocal DisableDelayedExpansion

set "SHADER_DIR=%~dp0"
set "OUT_DIR=%~1"
if not defined OUT_DIR set "OUT_DIR=%SHADER_DIR:~0,-1%"

echo Compiling shaders...

for %%S in (
    "ui_rect.frag"
    "ui_rect.vert"
) do (
    if not exist "%SHADER_DIR%%%~S" (
        echo   [WARN] Not found: "%SHADER_DIR%%%~S" -- skipping
    ) else (
        glslc --target-env=vulkan1.3 "%SHADER_DIR%%%~S" -o "%OUT_DIR%\%%~S.spv"
        if errorlevel 1 goto :compile_error
        echo   [OK]   %%~S  -^>  %%~S.spv
    )
)

echo Done.
exit /b 0

:compile_error
exit /b 1
