"""Yhteinen maailmageometria ja polut koko putkelle.

Kaikki koordinaattimuunnokset kulkevat taman moduulin lapi, jotta purku, albedo-bake,
renderointi ja lopullinen tiilitys pysyvat taysin samassa ruudukossa. Jos tama menee
vaaraan, kaikki muu menee vaaraan huomaamatta.

Koordinaatistot:
  UU      Unreal-yksikot, pelin maailmakoordinaatit (X oikealle, Y alas, Z ylos)
  metri   UU / uu_per_meter
  px      lopullisen kuvan pikselit, origo vasen ylakulma, +x oikealle, +y alas

UE:n Y-akseli kasvaa "etelaan" samoin kuin kuvan y, joten kierto ei ole tarpeen -
tama on tarkistettava verify_landmarks.py:lla ennen kuin mitaan renderoidaan.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONFIG = Path(os.environ.get("SCUM_CONFIG", REPO / "config"))
DUMP = Path(os.environ.get("SCUM_DUMP", REPO / "dump"))   # vaiheen A ulostulo
WORK = Path(os.environ.get("SCUM_WORK", REPO / "work"))   # valitulokset
OUT = Path(os.environ.get("SCUM_OUT", REPO / "out"))      # lopputuotteet

# UE4 landscape: korkeus talletetaan 16-bittisena, nollataso 32768, askel 1/128 UU.
LANDSCAPE_ZSCALE = 1.0 / 128.0
HEIGHT_MID = 32768


@dataclass
class World:
    """Maailman rajat ja ruudukko. Ladataan config/world.json:sta."""

    origin_uu: tuple[float, float]      # kartan vasen ylakulma UU:na (X, Y)
    size_uu: tuple[float, float]        # leveys ja korkeus UU:na
    output_px: int = 32768              # lopullisen neliokuvan sivu
    tile_grid: int = 16                 # tiilia per akseli
    uu_per_meter: float = 100.0
    landscape: dict = field(default_factory=dict)

    # ---------- johdetut ----------
    @property
    def tile_px(self) -> int:
        if self.output_px % self.tile_grid:
            raise ValueError("output_px ei jaudu tasan tile_gridilla")
        return self.output_px // self.tile_grid

    @property
    def uu_per_px(self) -> float:
        # Kartta pakotetaan nelioksi: pidempi akseli maaraa mittakaavan.
        return max(self.size_uu) / self.output_px

    @property
    def meters_per_px(self) -> float:
        return self.uu_per_px / self.uu_per_meter

    @property
    def tile_size_uu(self) -> float:
        return self.uu_per_px * self.tile_px

    # ---------- muunnokset ----------
    def uu_to_px(self, x_uu: float, y_uu: float) -> tuple[float, float]:
        return ((x_uu - self.origin_uu[0]) / self.uu_per_px,
                (y_uu - self.origin_uu[1]) / self.uu_per_px)

    def px_to_uu(self, x_px: float, y_px: float) -> tuple[float, float]:
        return (self.origin_uu[0] + x_px * self.uu_per_px,
                self.origin_uu[1] + y_px * self.uu_per_px)

    def tile_bounds_uu(self, tx: int, ty: int) -> tuple[float, float, float, float]:
        """Tiilen (tx, ty) rajat UU:na: (min_x, min_y, max_x, max_y)."""
        s = self.tile_size_uu
        x0 = self.origin_uu[0] + tx * s
        y0 = self.origin_uu[1] + ty * s
        return (x0, y0, x0 + s, y0 + s)

    def tile_center_uu(self, tx: int, ty: int) -> tuple[float, float]:
        x0, y0, x1, y1 = self.tile_bounds_uu(tx, ty)
        return ((x0 + x1) / 2.0, (y0 + y1) / 2.0)

    def tiles(self):
        for ty in range(self.tile_grid):
            for tx in range(self.tile_grid):
                yield tx, ty

    def tile_of_uu(self, x_uu: float, y_uu: float) -> tuple[int, int]:
        s = self.tile_size_uu
        tx = int((x_uu - self.origin_uu[0]) // s)
        ty = int((y_uu - self.origin_uu[1]) // s)
        return (max(0, min(self.tile_grid - 1, tx)),
                max(0, min(self.tile_grid - 1, ty)))

    # ---------- landscape ----------
    def landscape_height_uu(self, h16) -> "float":
        """16-bit heightmap-arvo -> maailman Z UU:na (toimii myos numpy-taulukolle)."""
        scale_z = self.landscape.get("scale", [100.0, 100.0, 100.0])[2]
        loc_z = self.landscape.get("location", [0.0, 0.0, 0.0])[2]
        return loc_z + (h16 - HEIGHT_MID) * LANDSCAPE_ZSCALE * scale_z

    # ---------- io ----------
    @classmethod
    def load(cls, path: Path | None = None) -> "World":
        path = Path(path or CONFIG / "world.json")
        if not path.exists():
            raise SystemExit(
                f"{path} puuttuu. Aja ensin pipeline/01_landscape/heightmap.py, "
                "joka kirjoittaa maailman rajat purkudatasta."
            )
        d = json.loads(path.read_text())
        return cls(
            origin_uu=tuple(d["origin_uu"]),
            size_uu=tuple(d["size_uu"]),
            output_px=d.get("output_px", 32768),
            tile_grid=d.get("tile_grid", 16),
            uu_per_meter=d.get("uu_per_meter", 100.0),
            landscape=d.get("landscape", {}),
        )

    def save(self, path: Path | None = None) -> Path:
        path = Path(path or CONFIG / "world.json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "origin_uu": list(self.origin_uu),
            "size_uu": list(self.size_uu),
            "output_px": self.output_px,
            "tile_grid": self.tile_grid,
            "uu_per_meter": self.uu_per_meter,
            "landscape": self.landscape,
            # Johdetut arvot mukaan, jotta viewer ja overlayt saavat ne ilman Pythonia.
            "_derived": {
                "tile_px": self.tile_px,
                "uu_per_px": self.uu_per_px,
                "meters_per_px": self.meters_per_px,
                "tile_size_uu": self.tile_size_uu,
                "map_size_m": [s / self.uu_per_meter for s in self.size_uu],
            },
        }, indent=2))
        return path


# Purku kirjoittaa tekstuurit sellaisenaan ja kertoo formaatin metadatassa.
# Kanavajarjestysta ei arvata: vaara arvaus tuottaisi maaston joka nayttaa
# uskottavalta mutta on vaara, eika sita huomaisi mistaan.
_CHANNEL_ORDER = {
    "PF_R8G8B8A8": (0, 1, 2, 3),
    "PF_B8G8R8A8": (2, 1, 0, 3),
    "PF_A8R8G8B8": (1, 2, 3, 0),
    "RGBA8": (0, 1, 2, 3),          # vanha dumppiformaatti
}


def load_raw_rgba(stem: Path):
    """Lataa vaiheen A dumppaaman .raw-tekstuurin -> (numpy (h, w, 4) RGBA, meta).

    Palautettu meta on normalisoitu pieniksi kirjaimiksi, jotta kutsujien ei tarvitse
    valittaa siita kirjoittiko sen System.Text.Json vai jokin vanhempi versio.
    """
    import numpy as np

    raw_meta = json.loads(Path(str(stem) + ".json").read_text())
    meta = {k[:1].lower() + k[1:]: v for k, v in raw_meta.items()}
    fmt = meta.get("pixelFormat") or meta.get("pixel_format") or meta.get("format", "")
    order = _CHANNEL_ORDER.get(fmt)
    if order is None:
        raise SystemExit(
            f"{stem}: tuntematon pikseliformaatti {fmt!r}.\n"
            f"Tuetut: {', '.join(sorted(_CHANNEL_ORDER))}.\n"
            "Tekstuuria ei tulkita arvaamalla - lisaa formaatti common.py:n "
            "_CHANNEL_ORDER-tauluun kun tiedat sen kanavajarjestyksen.")

    h, w = meta["height"], meta["width"]
    buf = np.fromfile(str(stem) + ".raw", dtype=np.uint8)
    expected = h * w * 4
    if buf.size != expected:
        raise SystemExit(f"{stem}: {buf.size} tavua, odotettiin {expected} ({w}x{h}x4)")

    img = buf.reshape(h, w, 4)
    return (img if order == (0, 1, 2, 3) else img[:, :, order]), meta


def ensure_dirs(*paths: Path) -> None:
    for p in paths:
        Path(p).mkdir(parents=True, exist_ok=True)
