@echo off
title Pro Cloud v2 — Sinyal Sistemi
cd /d "%~dp0"
color 0A

echo.
echo  ██████╗ ██████╗  ██████╗      ██████╗██╗      ██████╗ ██╗   ██╗██████╗
echo  ██╔══██╗██╔══██╗██╔═══██╗    ██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗
echo  ██████╔╝██████╔╝██║   ██║    ██║     ██║     ██║   ██║██║   ██║██║  ██║
echo  ██╔═══╝ ██╔══██╗██║   ██║    ██║     ██║     ██║   ██║██║   ██║██║  ██║
echo  ██║     ██║  ██║╚██████╔╝    ╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝
echo  ╚═╝     ╚═╝  ╚═╝ ╚═════╝      ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝
echo.
echo                          Pro Cloud v2 — Sinyal Sistemi
echo                          Sinyal → Telegram  7/24
echo.

REM ── TradingView Desktop'u CDP modunda başlat ─────────────────────
echo [1/3] TradingView kontrol ediliyor...
curl -s http://localhost:9222/json/version >nul 2>&1
if %errorlevel% equ 0 (
    echo       TradingView zaten acik - devam
    goto webhook
)

set "TV=C:\Program Files\WindowsApps\TradingView.Desktop_3.1.0.7818_x64__n534cwy3pjxzj\TradingView.exe"
if exist "%TV%" (
    start "" "%TV%" --remote-debugging-port=9222
    echo       Yukleniyor, 20 saniye bekleniyor...
    timeout /t 20 /nobreak >nul
) else (
    echo       TradingView Desktop bulunamadi.
    echo       Yine de devam ediliyor (webhook sunucusu calisacak).
)

:webhook
REM ── Webhook sunucusu başlat (TradingView Native Alert → Telegram) ─
echo [2/3] Webhook sunucusu basliyor (port 3001)...
start "Webhook" cmd /k "node scripts/webhook_server.mjs"
timeout /t 2 /nobreak >nul

:sinyal
REM ── CDP sinyal motoru başlat ──────────────────────────────────────
echo [3/3] CDP sinyal motoru basliyor...
echo.
echo  ═══════════════════════════════════════════════════
echo   Kapat: bu pencereyi kapat veya Ctrl+C
echo   Telegram: sinyal gelince mesaj gidecek
echo   Webhook:  ayri pencerede port 3001
echo  ═══════════════════════════════════════════════════
echo.
node scripts/sinyal.mjs

pause
