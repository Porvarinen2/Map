# -*- coding: utf-8 -*-
"""Ruudulta kolme lukua: kaanto, onko yritys kaynnissa, aukesiko lukko.

Katsottava alue on se joka referenssikuvassa on merkitty pinkilla:
keskus (959, 536) ja sade 128.5 kun ruutu on 1080p.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional

import numpy as np


@dataclass
class Saadot:
    keskus_y: float = -0.0037        # x ruudun korkeus, ruudun keskelta
    alue_sade: float = 0.1190        # 128.5 / 1080
    reika_sade: float = 0.0519       # musta avaimenreika pesan sisalla
    tumma_max: int = 22
    min_pikselit: int = 200
    min_pitkulaisuus: float = 1.8
    kaari_kirkas: int = 185
    kaari_min: int = 1500
    palkki_kirkas: int = 200
    palkki_min: int = 2500


@dataclass
class Kuva:
    ok: bool = False
    kaanto: float = 0.0
    kulma: float = 0.0
    kaynnissa: bool = False
    auki: bool = False


class Silma:
    def __init__(self, s: Optional[Saadot] = None):
        self.s = s or Saadot()
        self.koko = None
        self.edellinen = 0.0

    def avaa(self) -> int:
        import mss
        self.sct = mss.mss()
        m = self.sct.monitors
        paras, eniten = 1, -1
        for i in range(1, len(m)):
            n = m[i]
            p = int(0.30 * n["height"])
            cx, cy = n["left"] + n["width"] // 2, n["top"] + n["height"] // 2
            self.korkeus = n["height"]
            self.koko = None
            self.tulkitse(np.asarray(self.sct.grab(
                {"left": cx - p, "top": cy - p, "width": 2 * p, "height": 2 * p}))[:, :, :3])
            if self.kaari > eniten:
                paras, eniten = i, self.kaari
        n = m[paras]
        p = int(0.30 * n["height"])
        self.alue = {"left": n["left"] + n["width"] // 2 - p,
                     "top": n["top"] + n["height"] // 2 + int(self.s.keskus_y * n["height"]) - p,
                     "width": 2 * p, "height": 2 * p}
        self.korkeus = n["height"]
        self.koko = None
        return paras

    def lue(self) -> Kuva:
        return self.tulkitse(np.asarray(self.sct.grab(self.alue))[:, :, :3])

    def _maskit(self, korkeus, leveys):
        if self.koko != (korkeus, leveys):
            y = np.arange(korkeus, dtype=np.float32) - korkeus / 2.0
            x = np.arange(leveys, dtype=np.float32) - leveys / 2.0
            yy, xx = np.meshgrid(y, x, indexing="ij")
            et = np.sqrt(xx * xx + yy * yy)
            r = self.s.alue_sade * self.korkeus
            self.xx, self.yy = xx, yy
            self.reika_maski = et < self.s.reika_sade * self.korkeus
            self.kaari_maski = (et > r * 1.10) & (et < r * 1.85)
            ph = max(8, int(self.korkeus * 0.051))
            pw = max(8, int(self.korkeus * 0.204))
            self.palkki_alue = (slice(korkeus // 2 - ph, korkeus // 2 + ph),
                                slice(leveys // 2 - pw, leveys // 2 + pw))
            self.koko = (korkeus, leveys)

    def tulkitse(self, bgr) -> Kuva:
        k = (0.114 * bgr[:, :, 0].astype(np.float32)
             + 0.587 * bgr[:, :, 1].astype(np.float32)
             + 0.299 * bgr[:, :, 2].astype(np.float32))
        self._maskit(*k.shape)
        self.kaari = int(((k > self.s.kaari_kirkas) & self.kaari_maski).sum())
        self.palkki = int((k[self.palkki_alue] > self.s.palkki_kirkas).sum())
        auki = self.palkki >= self.s.palkki_min and self.kaari <= self.s.kaari_min // 2
        kaynnissa = self.kaari >= self.s.kaari_min

        reika = (k < self.s.tumma_max) & self.reika_maski
        if int(reika.sum()) < self.s.min_pikselit:
            return Kuva(False, 0.0, 0.0, kaynnissa, auki)
        kulma = self._suunta(self.xx[reika], self.yy[reika])
        if kulma is None:
            return Kuva(False, 0.0, 0.0, kaynnissa, auki)
        return Kuva(True, float(np.clip(kulma / 90.0, 0.0, 1.0)), kulma, kaynnissa, auki)

    def _suunta(self, x, y) -> Optional[float]:
        """Mustien pikselien paasuunta: lepo noin 0, auki noin 90 astetta."""
        x = x.astype(np.float64); y = y.astype(np.float64)
        x -= x.mean(); y -= y.mean()
        xx = float((x * x).mean()); yy = float((y * y).mean()); xy = float((x * y).mean())
        juuri = math.sqrt(max(0.0, (xx - yy) ** 2 + 4 * xy * xy))
        pieni, iso = (xx + yy - juuri) / 2, (xx + yy + juuri) / 2
        if pieni <= 1e-9 or math.sqrt(iso / pieni) < self.s.min_pitkulaisuus:
            return None
        a = math.degrees(0.5 * math.atan2(2 * xy, xx - yy)) + 90.0
        while a - self.edellinen > 90: a -= 180
        while self.edellinen - a > 90: a += 180
        while a < -25: a += 180
        while a > 125: a -= 180
        self.edellinen = a
        return a

    def nollaa(self):
        self.edellinen = 0.0
