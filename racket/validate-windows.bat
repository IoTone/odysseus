@echo off
rem validate-windows.bat — one-shot Windows validation for the Racket port.
rem Assumes Racket (official win32-cs) is installed and on PATH (see VALIDATION.md
rem step 1). Run by double-clicking or: racket\validate-windows.bat
rem
rem Does: install deps -> byte-compile -> run the test suite -> build a
rem standalone .exe and run it. Stops at the first failure.
setlocal EnableExtensions

where racket >nul 2>nul || (echo [X] Racket not found on PATH. See racket\VALIDATION.md step 1. & exit /b 1)
for /f "delims=" %%v in ('racket --version') do echo [i] %%v

set "SCRIPT_DIR=%~dp0"
set "ROOT=%SCRIPT_DIR%.."

echo.
echo == 1/4  dependencies (catalog libs + local packages) ==
pushd "%ROOT%" || exit /b 1
raco pkg install --auto --batch --skip-installed web-server-lib db-lib || (echo [X] dep install failed & popd & exit /b 1)
raco pkg install --link --batch --skip-installed racket\pkgs\cli-kit racket\pkgs\db-kit racket\pkgs\web-kit || (echo [X] kit link failed & popd & exit /b 1)
popd

pushd "%SCRIPT_DIR%" || exit /b 1

echo.
echo == 2/4  byte-compile (explicit list; PowerShell/cmd don't expand *.rkt) ==
raco make config.rkt cli/odysseus-logs.rkt cli/odysseus-preset.rkt cli/odysseus-signature.rkt cli/odysseus-notes.rkt cli/odysseus-sessions.rkt cli/odysseus-tasks.rkt cli/odysseus-research.rkt cli/odysseus-mcp.rkt cli/odysseus-calendar.rkt domain/notes.rkt domain/sessions.rkt server/main.rkt server/proxy.rkt test/run-tests.rkt || (echo [X] BUILD FAILED & popd & exit /b 1)
echo [ok] build clean

echo.
echo == 3/4  test suite (expect: 10 success^(es^)) ==
racket test/run-tests.rkt || (echo [X] TESTS FAILED & popd & exit /b 1)

echo.
echo == 4/4  packaging: raco exe + run the binary (the key Windows check) ==
if not exist dist mkdir dist
raco exe -o dist\odysseus-logs.exe cli/odysseus-logs.rkt || (echo [X] raco exe FAILED & popd & exit /b 1)
dist\odysseus-logs.exe --version || (echo [X] standalone binary CRASHED on run & popd & exit /b 1)

popd
echo.
echo =====================================================
echo  ALL GREEN — racket port validates on this Windows box
echo  Report: version OK, build OK, suite=10, raco exe runs.
echo =====================================================
endlocal
