@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo  PACK LATEST DEBUG SESSION
echo ============================================================
echo.
echo Normally the macro creates debug_session_*.zip automatically on F9.
echo If a debug_sessions\session_* folder exists without a zip, this packs it.
echo.

py -c "from pathlib import Path; import zipfile; base=Path.cwd(); root=base/'debug_sessions'; sessions=sorted([p for p in root.glob('session_*') if p.is_dir()], key=lambda p:p.stat().st_mtime); assert sessions, 'No session folders found'; s=sessions[-1]; out=base/(s.name+'.zip'); z=zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED); [z.write(p,p.relative_to(s)) for p in s.rglob('*') if p.is_file()]; z.close(); print('Created:',out)"

echo.
pause
