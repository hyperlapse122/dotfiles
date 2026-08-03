@echo off
rem Hermetic fake of Windows netsh for the import-wifi-1password.ps1 fixtures.
rem Logs its full argv (one call per line) to %TEST_LOG% so the caller can
rem scan for verb counts AND prove no secret ever rode a command line; never
rem prints profile file contents.
rem
rem Controls (environment):
rem   TEST_LOG                     required; argv log path.
rem   TEST_STATE_DIR               required for BLOCK mode.
rem   WIFI_FAKE_FAIL_STAGE=add^|delete^|set   exit /b 42 on every call whose
rem                                           wlan verb matches.
rem   WIFI_FAKE_BLOCK=add          on that verb, write %TEST_STATE_DIR%\blocked
rem                                and wait for %TEST_STATE_DIR%\unblock (the
rem                                cancellation fixture stops the tool while
rem                                this fake is parked here).
setlocal
>>"%TEST_LOG%" echo netsh %*

set "verb=%~2"

if /i "%WIFI_FAKE_BLOCK%"=="%verb%" if not "%verb%"=="" (
  >>"%TEST_STATE_DIR%\blocked" echo blocked
  :wifi_fake_wait
  if exist "%TEST_STATE_DIR%\unblock" goto wifi_fake_unblocked
  ping -n 2 127.0.0.1 >nul
  goto wifi_fake_wait
)
:wifi_fake_unblocked

if /i "%WIFI_FAKE_FAIL_STAGE%"=="%verb%" if not "%verb%"=="" exit /b 42


rem Every other verb used by the tool (add / delete / set profileorder)
rem succeeds silently.
exit /b 0
