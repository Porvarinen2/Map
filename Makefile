# SCUM 32K ortokartta - ajojarjestys.
#
# Windowsissa ei tarvita makea: aja RUN_ALL.bat, joka tekee kaiken taman
# automaattisesti (tools/run_pipeline.py). Tama Makefile on Linux/mac-polku.
#
#   make selftest                       tarkista putki ilman pelidataa
#   make extract PAKS="D:/.../Paks" AES=0x...
#   make landscape verify               korkeuskartta + koordinaattitarkistus
#   make ground                         M2: 32K maanpinta ilman objekteja
#   make library scene render           M3-M4: objektit ja renderointi
#   make web                            M5: tiilet ja katselin
#
# Milestonet ajetaan jarjestyksessa ja jokainen tuottaa katsottavan tuloksen.
# Jos verify ei mene lapi, ala jatka - virhe kertautuu kaikkiin myohempiin vaiheisiin.

PY      ?= python3
BLENDER ?= blender
PAKS    ?=
AES     ?=
GAME    ?= GAME_UE4_27
OUTPX   ?= 32768
GRID    ?= 16
ENGINE  ?= cycles
SAMPLES ?= 256

.PHONY: all auto selftest extract landscape verify layers ground ground-flat \
        library scene render stitch web clean

all: landscape verify layers ground library scene render stitch web

# Sama kuin RUN_ALL.bat: ajaa kaiken ja jatkaa keskeytyneesta kohdasta.
auto:
	$(PY) tools/run_pipeline.py

selftest:
	$(PY) tools/selftest.py

## --- A: purku (vaatii Windowsin ja pelin paketit) ---
extract:
	@test -n "$(PAKS)" || (echo "Anna PAKS=<polku SCUM/Content/Paks>"; exit 1)
	cd pipeline/00_extract/DumpWorld && dotnet run -c Release -- \
		--paks "$(PAKS)" --aes "$(AES)" --game $(GAME) --out "$(CURDIR)/dump" \
		--meshes "$(CURDIR)/assets/meshes" \
		--landscape-textures "$(CURDIR)/assets/landscape"

## --- B: maasto ja maailman rajat ---
landscape:
	$(PY) pipeline/01_landscape/heightmap.py --output-px $(OUTPX) --tile-grid $(GRID)
	$(PY) pipeline/01_landscape/weightmaps.py

verify:
	$(PY) pipeline/02_scene/verify_landmarks.py --draw work/heightmap_u16.png

## --- C: maanpinnan albedo ---
# layers = arvaa config/layers.json materiaalin tekstuureista (viilaa kasin jalkeenpain)
layers:
	$(PY) pipeline/01_landscape/guess_layers.py --texture-dir assets/landscape

# ground      = valmis kartta katsottavaksi (reliefivarjostus mukana)
# ground-flat = Blenderin syote (ei varjostusta - valo tulee renderissa auringosta)
ground: ground-flat
	$(PY) pipeline/01_landscape/ground_albedo.py --hillshade 0.35

ground-flat:
	$(PY) pipeline/01_landscape/ground_albedo.py --hillshade 0 --out work/ground_flat

## --- D: objektit ---
library:
	$(BLENDER) -b -P pipeline/03_render/build_library.py -- --meshes assets/meshes

scene:
	$(PY) pipeline/02_scene/actor_db.py --min-px 2

## --- E: renderointi ---
render:
	$(PY) pipeline/03_render/render_all.py --blender $(BLENDER) \
		--engine $(ENGINE) --samples $(SAMPLES)

## --- F: kokoaminen ja jakelu ---
stitch:
	$(PY) pipeline/04_output/stitch.py

web: stitch
	$(PY) pipeline/04_output/make_tiles.py

clean:
	rm -rf work out
