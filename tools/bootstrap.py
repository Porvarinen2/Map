#!/usr/bin/env python3
"""Pystyttaa ajoymparistin: tyokalut, venv, riippuvuudet, CUE4Parse ja DumpWorld.

Ajetaan ensimmaisella kerralla; tulos jaa muistiin config/settings.ini, joten
seuraavat ajot menevat suoraan asiaan.

Periaate: mitaan jarjestelmaohjelmistoa ei asenneta kysymatta. Puuttuvasta kerrotaan
tarkka winget-komento ja tarjotaan sen ajamista - .bat-tiedosto ei saa ryhtya
asentelemaan kayttajan koneelle asioita selan takana.
"""
from __future__ import annotations

import configparser
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SETTINGS = REPO / "config" / "settings.ini"
VENV = REPO / ".venv"
CUE4PARSE = REPO / "tools" / "CUE4Parse"
CUE4PARSE_URL = "https://github.com/FabianFG/CUE4Parse"
# Pinnattu kommitti. CUE4Parsen master muuttaa API:aan jatkuvasti, ja tata vasten
# DumpWorld on kaannetty ja testattu - ilman pinnia kaannos voi hajota milla hetkella
# hyvansa ilman etta taalla on muutettu mitaan.
CUE4PARSE_COMMIT = "cfff57a0483501e0fa555dff5bf542748afe0bab"
# CUE4Parse kohdistaa net10.0:aan, joten vanhempi SDK ei kelpaa.
DOTNET_MIN_MAJOR = 10

IS_WIN = os.name == "nt"
PY_DEPS = ["numpy", "pillow"]
PY_DEPS_OPTIONAL = ["pyvips[binary]"]      # libvips mukana; ilman tata PIL-varareitti

TOOLS = {
    "dotnet": ("Microsoft.DotNet.SDK.10", "https://dotnet.microsoft.com/download"),
    "git": ("Git.Git", "https://git-scm.com/downloads"),
}


# ---------------------------------------------------------------- asetukset

class Settings:
    """config/settings.ini - yksi paikka jossa kaikki koneen polut asuvat."""

    def __init__(self, path: Path = SETTINGS):
        self.path = path
        self.cp = configparser.ConfigParser()
        self.cp.read(path) if path.exists() else None
        for section in ("paths", "render"):
            if not self.cp.has_section(section):
                self.cp.add_section(section)

    def get(self, section: str, key: str, default: str = "") -> str:
        return self.cp.get(section, key, fallback=default)

    def set(self, section: str, key: str, value) -> None:
        self.cp.set(section, key, str(value))

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("w") as f:
            self.cp.write(f)


# ---------------------------------------------------------------- kayttoliittyma

def say(msg: str = "") -> None:
    print(msg, flush=True)


def ask(question: str, default: str = "", interactive: bool = True) -> str:
    if not interactive:
        return default
    hint = f" [{default}]" if default else ""
    try:
        got = input(f"{question}{hint}: ").strip()
    except EOFError:
        return default
    return got or default


def confirm(question: str, interactive: bool = True, default: bool = False) -> bool:
    if not interactive:
        return default
    return ask(f"{question} (k/e)", "k" if default else "e", True).lower().startswith("k")


# ---------------------------------------------------------------- tyokalut

def which(name: str) -> str | None:
    return shutil.which(name)


def dotnet_major() -> int:
    """Suurin asennettu .NET SDK -paaversio, 0 jos dotnetia ei ole."""
    if not which("dotnet"):
        return 0
    try:
        out = subprocess.run(["dotnet", "--list-sdks"], capture_output=True, text=True)
        return max((int(line.split(".")[0]) for line in out.stdout.splitlines()
                    if line[:1].isdigit()), default=0)
    except Exception:                                             # noqa: BLE001
        return 0


def require_tools(interactive: bool) -> list[str]:
    """Tarkista tyokalut ja tarjoa winget-asennusta puuttuville."""
    missing = []
    for tool, (winget_id, url) in TOOLS.items():
        if tool == "dotnet":
            have = dotnet_major()
            if have >= DOTNET_MIN_MAJOR:
                continue
            say(f"  .NET SDK {DOTNET_MIN_MAJOR} puuttuu"
                + (f" (asennettuna {have})" if have else ""))
        elif which(tool):
            continue
        else:
            say(f"  puuttuu: {tool}")

        if IS_WIN and which("winget") and confirm(
                f"    asennetaanko nyt komennolla 'winget install {winget_id}'?",
                interactive):
            subprocess.run(["winget", "install", "-e", "--id", winget_id,
                            "--accept-package-agreements", "--accept-source-agreements"])
            ok = dotnet_major() >= DOTNET_MIN_MAJOR if tool == "dotnet" else bool(which(tool))
            if ok:
                say(f"    {tool} asennettu")
                continue
            say("    asennus ei nakynyt viela PATHissa - kaynnista ikkuna uudelleen")
        else:
            say(f"    asenna itse: {url}")
        missing.append(tool)
    return missing


def find_blender(settings: Settings, interactive: bool) -> str | None:
    known = settings.get("paths", "blender")
    if known and Path(known).exists():
        return known

    found = which("blender")
    if not found and IS_WIN:
        roots = [Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")),
                 Path(os.environ.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)"))]
        cands = []
        for root in roots:
            cands += sorted((root / "Blender Foundation").glob("Blender */blender.exe"))
            cands += sorted(root.glob("Steam/steamapps/common/Blender/blender.exe"))
        found = str(cands[-1]) if cands else None      # uusin versio viimeisena

    if not found:
        say("  Blenderia ei loytynyt.")
        if IS_WIN and which("winget") and confirm(
                "    asennetaanko 'winget install BlenderFoundation.Blender'?", interactive):
            subprocess.run(["winget", "install", "-e", "--id", "BlenderFoundation.Blender",
                            "--accept-package-agreements", "--accept-source-agreements"])
            found = which("blender")
        if not found:
            found = ask("    anna blender.exe:n polku (tyhja = ohita renderointi)",
                        "", interactive) or None

    if found:
        settings.set("paths", "blender", found)
    return found


def find_scum_paks(settings: Settings, interactive: bool) -> str | None:
    known = settings.get("paths", "paks")
    if known and Path(known).exists():
        return known

    for lib in steam_libraries():
        p = lib / "steamapps" / "common" / "SCUM" / "SCUM" / "Content" / "Paks"
        if p.exists():
            say(f"  SCUM loytyi: {p}")
            settings.set("paths", "paks", str(p))
            return str(p)

    say("  SCUMin asennusta ei loytynyt automaattisesti.")
    got = ask("    anna polku SCUM/Content/Paks -kansioon", "", interactive)
    if got:
        settings.set("paths", "paks", got)
    return got or None


def steam_libraries() -> list[Path]:
    """Steamin kirjastokansiot. Peli on harvoin samalla levylla kuin Steam itse."""
    roots: list[Path] = []
    if IS_WIN:
        try:
            import winreg                                    # type: ignore
            for hive, key in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam"),
                              (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam")):
                try:
                    with winreg.OpenKey(hive, key) as k:
                        roots.append(Path(winreg.QueryValueEx(k, "SteamPath")[0]))
                except OSError:
                    pass
        except ImportError:
            pass
        roots += [Path(r"C:\Program Files (x86)\Steam"), Path(r"C:\Steam")]
    else:
        roots += [Path.home() / ".steam/steam", Path.home() / ".local/share/Steam"]

    libs: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        libs.append(root)
        vdf = root / "steamapps" / "libraryfolders.vdf"
        if vdf.exists():
            # Kevyt regex-parsi: vdf-kirjastoa ei kannata vaatia yhden kentan takia.
            for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text(errors="ignore")):
                libs.append(Path(m.group(1).replace("\\\\", "\\")))
    return list(dict.fromkeys(libs))


# ---------------------------------------------------------------- python-ymparisto

def venv_python() -> Path:
    return VENV / ("Scripts/python.exe" if IS_WIN else "bin/python")


def ensure_venv() -> Path:
    py = venv_python()
    if not py.exists():
        say("  luodaan .venv")
        subprocess.run([sys.executable, "-m", "venv", str(VENV)], check=True)
    # Vanha pip ei osaa kaikkia nykyisia wheel-muotoja, ja venviin tulee usein
    # se versio joka sattui olemaan Pythonin mukana vuosia sitten.
    subprocess.run([str(py), "-m", "pip", "install", "--quiet", "--upgrade", "pip"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return py


def pip_install(py: Path, packages: list[str], optional: bool = False) -> bool:
    cmd = [str(py), "-m", "pip", "install", "--quiet", "--upgrade", *packages]
    r = subprocess.run(cmd)
    if r.returncode and not optional:
        raise SystemExit(f"pip epaonnistui: {' '.join(packages)}")
    return r.returncode == 0


def in_venv() -> bool:
    """Ollaanko jo taman repon virtuaaliymparistossa.

    Vertailu tehdaan sys.prefixilla eika tulkin polulla: Linuxissa venvin python on
    symlinkki perustulkkiin, jolloin polkujen vertailu luulisi aina olevansa venvissa
    eika vaihtoa tapahtuisi koskaan.
    """
    try:
        return Path(sys.prefix).resolve() == VENV.resolve()
    except OSError:
        return False


# ---------------------------------------------------------------- CUE4Parse

def ensure_cue4parse(interactive: bool) -> bool:
    if (CUE4PARSE / "CUE4Parse" / "CUE4Parse.csproj").exists():
        return True
    if not which("git"):
        say("  git puuttuu - CUE4Parsea ei voi hakea")
        return False

    say(f"  kloonataan CUE4Parse -> {CUE4PARSE}")
    CUE4PARSE.parent.mkdir(parents=True, exist_ok=True)

    # EI --recursive. Submodulit ovat vain natiivikirjastoja varten, ja niiden
    # ketju (ACL -> sjson-cpp -> catch2) ylittaa Windowsin polkurajan pitkan
    # kansiopolun alla - juuri se kaatoi ensimmaisen ajon.
    r = subprocess.run(["git", "-c", "core.longpaths=true", "clone",
                        "--filter=blob:none", CUE4PARSE_URL, str(CUE4PARSE)])
    if r.returncode:
        return False

    r = subprocess.run(["git", "checkout", "--quiet", CUE4PARSE_COMMIT], cwd=CUE4PARSE)
    if r.returncode:
        say(f"  VAROITUS: kommittia {CUE4PARSE_COMMIT[:10]} ei loytynyt, "
            "kaytetaan masteria (API on voinut muuttua)")
    return True


def build_dumpworld() -> Path | None:
    proj = REPO / "pipeline" / "00_extract" / "DumpWorld"
    if dotnet_major() < DOTNET_MIN_MAJOR:
        say(f"  .NET SDK {DOTNET_MIN_MAJOR} puuttuu - DumpWorldia ei voi kaantaa")
        return None

    say("  kaannetaan DumpWorld (ensimmainen kerta kestaa muutaman minuutin)")
    # CUE4PARSE_SKIP_NATIVE globaalina propertyna valittyy myos viitattuihin
    # projekteihin, jolloin CMake-vaihe jaa pois kokonaan.
    r = subprocess.run(
        ["dotnet", "build", "-c", "Release", "--nologo",
         "-p:CUE4PARSE_SKIP_NATIVE=true"],
        cwd=proj, capture_output=True, text=True)

    if r.returncode:
        say("  kaannos epaonnistui:")
        errors = [ln for ln in r.stdout.splitlines() if ": error " in ln]
        for line in (errors or r.stdout.splitlines())[-12:]:
            say(f"    {line.strip()}")
        return None

    exe = next((p for p in sorted(proj.glob("bin/Release/net*/DumpWorld*"))
                if p.suffix in ("", ".exe")), None)
    if exe:
        say(f"  kaannetty: {exe.name}")
    return exe


# ---------------------------------------------------------------- paaohjelma

def ensure(interactive: bool = True) -> Settings:
    """Aja koko pystytys ja palauta tallennetut asetukset."""
    s = Settings()

    say("[1/5] tyokalut")
    require_tools(interactive)

    say("[2/5] Python-riippuvuudet")
    py = ensure_venv()
    pip_install(py, PY_DEPS)
    if pip_install(py, PY_DEPS_OPTIONAL, optional=True):
        say("  pyvips ok (32K-master kaytettavissa)")
    else:
        say("  pyvips ei asentunut - kaytetaan PIL-varareittia, 32K-master jaa tekematta")

    say("[3/5] CUE4Parse")
    ensure_cue4parse(interactive)

    say("[4/5] DumpWorld")
    exe = build_dumpworld()
    if exe:
        s.set("paths", "dumpworld", str(exe))
    else:
        s.set("paths", "dumpworld", "")

    say("[5/5] pelin ja Blenderin polut")
    find_scum_paks(s, interactive)
    find_blender(s, interactive)

    if not s.get("paths", "aes"):
        say("  SCUMin pakettien AES-avain.")
        s.set("paths", "aes", ask("    AES-avain (0x...)", "", interactive))
    if not s.get("paths", "game"):
        s.set("paths", "game", "GAME_UE4_27")

    for key, default in (("output_px", "32768"), ("tile_grid", "16"),
                         ("engine", "cycles"), ("samples", "256")):
        if not s.get("render", key):
            s.set("render", key, default)

    s.save()
    say(f"\nAsetukset -> {s.path}")
    return s


if __name__ == "__main__":
    ensure(interactive="--yes" not in sys.argv)
