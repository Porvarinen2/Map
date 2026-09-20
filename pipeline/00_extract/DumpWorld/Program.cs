// Vaihe A: purkaa SCUMin .pak-tiedostoista kaiken sen datan jota kartanteko tarvitsee -
// mukaan lukien meshit, joten FModelia ei tarvita eika putkessa ole yhtaan kasin
// tehtavaa valivaihetta.
//
// Kaytto:
//   DumpWorld --paks "C:\...\SCUM\Content\Paks" --aes 0x<avain> --out dump
//             --meshes assets\meshes --landscape-textures assets\landscape
//
// Suunnittelun kaksi periaatetta:
//
//   1) Tekstuurit kirjoitetaan RAAKANA ja kanavajarjestys kerrotaan metadatassa.
//      Landscapen korkeus on 16-bittinen luku kahdessa varikanavassa; jos kanavat
//      tulkitaan vaarin, maasto nayttaa taysin uskottavalta mutta on vaara. Siksi
//      talla puolella ei arvata mitaan eika enkoodata PNG:ksi - Python lukee
//      formaatin sivutiedostosta ja normalisoi sen itse.
//
//   2) Ei yhtaan NuGet-riippuvuutta. CUE4Parse kayttaa keskitettya paketinhallintaa
//      eksakteilla versiopinneilla, joten omat pinnit vain aiheuttaisivat
//      versioristiriitoja. JSON hoituu System.Text.Jsonilla joka tulee runtimessa.

using System.Text;
using System.Text.Json;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse.UE4.Assets.Exports.Component.StaticMesh;
using CUE4Parse.UE4.Assets.Exports.Material;
using CUE4Parse.UE4.Assets.Exports.StaticMesh;
using CUE4Parse.UE4.Assets.Exports.Texture;
using CUE4Parse.UE4.Assets.Objects;
using CUE4Parse.UE4.Objects.Core.Math;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Objects.UObject;
using CUE4Parse.UE4.Versions;
using CUE4Parse_Conversion;
using CUE4Parse_Conversion.Options;
using CUE4Parse_Conversion.Textures;

namespace DumpWorld;

internal static class Program
{
    private static string _out = "dump";
    private static readonly HashSet<string> DumpedTextures = new();
    private static readonly HashSet<string> NeededMeshes = new();
    private static FPackageIndex? _landscapeMaterial;

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    private static int Main(string[] args)
    {
        var paks = Arg(args, "--paks");
        var aes = Arg(args, "--aes") ?? "";
        _out = Arg(args, "--out") ?? "dump";
        var gameName = Arg(args, "--game") ?? "GAME_UE4_27";
        var filter = Arg(args, "--filter");
        var meshDir = Arg(args, "--meshes");
        var landDir = Arg(args, "--landscape-textures");
        var exportMaterials = !args.Contains("--no-materials");
        var layerTexturesOnly = args.Contains("--layer-textures-only");

        if (paks == null)
        {
            Console.Error.WriteLine(
                "Kaytto: --paks <polku> [--aes 0x..] [--out dump] [--game GAME_UE4_27]\n"
                + "        [--filter Maps/] [--meshes <dir>] [--landscape-textures <dir>]\n"
                + "        [--no-materials] [--layer-textures-only]");
            return 1;
        }

        if (!Enum.TryParse<EGame>(gameName, out var game))
        {
            Console.Error.WriteLine($"Tuntematon --game '{gameName}'. Katso CUE4Parse EGame-enum.");
            return 1;
        }

        foreach (var sub in new[] { "textures", "actors", "foliage", "landscape" })
            Directory.CreateDirectory(Path.Combine(_out, sub));

        Console.WriteLine($"Avataan {paks} ({game})...");
        var provider = new DefaultFileProvider(paks, SearchOption.AllDirectories,
            new VersionContainer(game), StringComparer.OrdinalIgnoreCase);
        provider.Initialize();
        provider.Mount();                                  // salaamattomat paketit
        if (!string.IsNullOrWhiteSpace(aes))
            provider.SubmitKey(new FGuid(), new FAesKey(aes));   // salatut paketit
        provider.LoadVirtualPaths();

        // Kevyt tila: etsii vain maa-ainesten varitekstuurit valmiin purun pohjalta.
        // Ajaa minuutissa, joten varien korjaaminen ei vaadi koko purun toistamista.
        if (layerTexturesOnly)
            return FindLayerTextures(provider, landDir ?? "assets/landscape");

        var maps = provider.Files.Keys
            .Where(k => k.EndsWith(".umap", StringComparison.OrdinalIgnoreCase))
            .Where(k => filter == null || k.Contains(filter, StringComparison.OrdinalIgnoreCase))
            .OrderBy(k => k)
            .ToList();
        Console.WriteLine($"{provider.Files.Count} tiedostoa mountattu, {maps.Count} umap-pakettia.");
        if (maps.Count == 0)
        {
            Console.Error.WriteLine(
                "Yhtaan umap-pakettia ei loytynyt. Yleisimmat syyt ovat vaara --game "
                + "tai vaara/puuttuva AES-avain.");
            return 2;
        }

        var landscape = new List<LandscapeComponentRec>();
        var landscapeActors = new List<ActorTransformRec>();
        var done = 0;

        foreach (var map in maps)
        {
            var levelName = Sanitize(Path.GetFileNameWithoutExtension(map));
            List<UObject> exports;
            try
            {
                exports = provider.LoadPackage(map).GetExports().ToList();
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"  ohitetaan {map}: {e.Message}");
                continue;
            }

            var statics = new List<StaticActorRec>();
            var foliage = new List<FoliageGroupRec>();

            foreach (var export in exports)
            {
                switch (export.ExportType)
                {
                    case "LandscapeComponent":
                        landscape.Add(ReadLandscapeComponent(export, levelName));
                        continue;

                    case "Landscape":
                    case "LandscapeStreamingProxy":
                        landscapeActors.Add(ReadActorTransform(export, levelName));
                        _landscapeMaterial ??= export.GetOrDefault<FPackageIndex>("LandscapeMaterial");
                        continue;
                }

                // Kasvillisuus ennen tavallisia meshkomponentteja: HISM perii SMC:n.
                if (export is UInstancedStaticMeshComponent ism)
                {
                    var rec = ReadFoliage(ism, levelName, foliage.Count);
                    if (rec != null) foliage.Add(rec);
                    continue;
                }

                if (export is UStaticMeshComponent smc)
                {
                    var rec = ReadStaticMesh(smc);
                    if (rec != null) statics.Add(rec);
                }
            }

            if (statics.Count > 0)
                WriteJson(Path.Combine(_out, "actors", levelName + ".json"), statics);
            if (foliage.Count > 0)
                WriteJson(Path.Combine(_out, "foliage", levelName + ".json"), foliage);

            if (++done % 50 == 0) Console.WriteLine($"  {done}/{maps.Count}");
        }

        WriteJson(Path.Combine(_out, "landscape", "components.json"), landscape);
        WriteJson(Path.Combine(_out, "landscape", "actors.json"), landscapeActors);
        File.WriteAllLines(Path.Combine(_out, "meshes_needed.txt"), NeededMeshes.OrderBy(x => x));

        DumpLandscapeMaterial(landDir);

        Console.WriteLine($"Purettu: {landscape.Count} landscape-komponenttia, "
                          + $"{DumpedTextures.Count} tekstuuria, {NeededMeshes.Count} uniikkia meshia.");

        if (meshDir != null)
            ExportMeshes(provider, meshDir, exportMaterials).GetAwaiter().GetResult();

        return 0;
    }

    // ---------------------------------------------------------------- landscape

    private static LandscapeComponentRec ReadLandscapeComponent(UObject c, string level)
    {
        var hsb = c.GetOrDefault("HeightmapScaleBias", new FVector4(0, 0, 0, 0));
        var wsb = c.GetOrDefault("WeightmapScaleBias", new FVector4(0, 0, 0, 0));
        var wtex = c.GetOrDefault<FPackageIndex[]>("WeightmapTextures") ?? [];
        var allocs = c.GetOrDefault<FStructFallback[]>("WeightmapLayerAllocations") ?? [];

        return new LandscapeComponentRec
        {
            Level = level,
            SectionBaseX = c.GetOrDefault("SectionBaseX", 0),
            SectionBaseY = c.GetOrDefault("SectionBaseY", 0),
            ComponentSizeQuads = c.GetOrDefault("ComponentSizeQuads", 63),
            SubsectionSizeQuads = c.GetOrDefault("SubsectionSizeQuads", 63),
            NumSubsections = c.GetOrDefault("NumSubsections", 1),
            Heightmap = DumpTexture(c.GetOrDefault<FPackageIndex>("HeightmapTexture")),
            HeightmapScaleBias = [hsb.X, hsb.Y, hsb.Z, hsb.W],
            WeightmapScaleBias = [wsb.X, wsb.Y, wsb.Z, wsb.W],
            WeightmapTextures = wtex.Select(DumpTexture).ToArray(),
            Layers = allocs.Select(a => new LayerAllocRec
            {
                Name = ShortName(a.GetOrDefault<FPackageIndex>("LayerInfo")),
                TextureIndex = a.GetOrDefault("WeightmapTextureIndex", (byte)0),
                Channel = a.GetOrDefault("WeightmapTextureChannel", (byte)0),
            }).ToArray(),
        };
    }

    /// Kirjoittaa tekstuurin purettuna mutta pakkaamattomana, ja kertoo mika
    /// pikseliformaatti se on. Tama on koko heightmap-purun ydin: Python paattelee
    /// kanavajarjestyksen metadatasta eika arvaa sita.
    private static string? DumpTexture(FPackageIndex? idx)
    {
        if (idx == null || idx.IsNull) return null;
        var tex = idx.Load<UTexture2D>();
        if (tex == null) return null;

        var key = Sanitize(tex.GetPathName());
        if (!DumpedTextures.Add(key)) return key;

        try
        {
            var bitmap = tex.Decode();
            if (bitmap == null)
            {
                DumpedTextures.Remove(key);
                return null;
            }

            File.WriteAllBytes(Path.Combine(_out, "textures", key + ".raw"), bitmap.Data);
            WriteJson(Path.Combine(_out, "textures", key + ".json"), new TextureMetaRec
            {
                Width = bitmap.Width,
                Height = bitmap.Height,
                PixelFormat = bitmap.PixelFormat.ToString(),
                Source = tex.GetPathName(),
            });
            return key;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"  tekstuuri {key}: {e.Message}");
            DumpedTextures.Remove(key);
            return null;
        }
    }

    /// Landscape-materiaalin tekstuuriparametrit ja skalaarit. Naiden avulla
    /// guess_layers.py yhdistaa layer-nimen oikeaan maa-aineksen tekstuuriin.
    private static void DumpLandscapeMaterial(string? textureDir)
    {
        if (_landscapeMaterial == null || _landscapeMaterial.IsNull)
        {
            Console.WriteLine("Landscape-materiaalia ei loytynyt - layer-varit arvataan nimista.");
            return;
        }

        var mat = _landscapeMaterial.Load<UMaterialInterface>();
        if (mat == null) return;

        var textures = new List<MaterialTextureRec>();
        foreach (var tp in mat.GetOrDefault<FStructFallback[]>("TextureParameterValues") ?? [])
        {
            var texIdx = tp.GetOrDefault<FPackageIndex>("ParameterValue");
            var texPath = texIdx?.ResolvedObject?.GetPathName();
            if (texPath == null) continue;

            textures.Add(new MaterialTextureRec
            {
                Parameter = ParameterName(tp),
                Texture = texPath,
                File = textureDir != null ? DumpMaterialTexture(texIdx!, textureDir) : null,
            });
        }

        var scalars = (mat.GetOrDefault<FStructFallback[]>("ScalarParameterValues") ?? [])
            .Select(sp => new MaterialScalarRec
            {
                Parameter = ParameterName(sp),
                Value = sp.GetOrDefault("ParameterValue", 0f),
            }).ToArray();

        WriteJson(Path.Combine(_out, "landscape", "material.json"), new MaterialRec
        {
            Material = mat.GetPathName(),
            Textures = textures.ToArray(),
            Scalars = scalars,
        });
        Console.WriteLine($"Landscape-materiaali: {textures.Count} tekstuuria, {scalars.Length} skalaaria.");
    }

    /// Maa-aineksen varitekstuuri omaan kansioonsa, samassa raakamuodossa.
    /// Python muuntaa nama PNG:ksi - taalla ei enkoodata mitaan.
    private static string? DumpMaterialTexture(FPackageIndex idx, string dir)
    {
        try
        {
            var tex = idx.Load<UTexture2D>();
            if (tex == null) return null;
            Directory.CreateDirectory(dir);

            var name = Sanitize(tex.Name);
            var raw = Path.Combine(dir, name + ".raw");
            if (File.Exists(raw)) return name;

            var bitmap = tex.Decode();
            if (bitmap == null) return null;

            File.WriteAllBytes(raw, bitmap.Data);
            WriteJson(Path.Combine(dir, name + ".json"), new TextureMetaRec
            {
                Width = bitmap.Width,
                Height = bitmap.Height,
                PixelFormat = bitmap.PixelFormat.ToString(),
                Source = tex.GetPathName(),
            });
            return name;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"  landscape-tekstuuri: {e.Message}");
            return null;
        }
    }

    private static string ParameterName(FStructFallback p) =>
        p.GetOrDefault<FStructFallback>("ParameterInfo")?.GetOrDefault<FName>("Name").Text
        ?? p.GetOrDefault<FName>("ParameterName").Text
        ?? "?";

    // ---------------------------------------------------------------- actorit

    private static StaticActorRec? ReadStaticMesh(UStaticMeshComponent c)
    {
        var mesh = c.GetOrDefault<FPackageIndex>("StaticMesh")?.ResolvedObject?.GetPathName();
        if (mesh == null) return null;
        NeededMeshes.Add(mesh);

        var (loc, rot, scale) = WorldTransform(c);
        return new StaticActorRec
        {
            Mesh = mesh,
            Loc = [loc.X, loc.Y, loc.Z],
            Rot = [rot.Pitch, rot.Yaw, rot.Roll],
            Scale = [scale.X, scale.Y, scale.Z],
        };
    }

    private static FoliageGroupRec? ReadFoliage(UInstancedStaticMeshComponent ism, string level, int slot)
    {
        var data = ism.PerInstanceSMData;
        if (data == null || data.Length == 0) return null;

        var mesh = ism.GetOrDefault<FPackageIndex>("StaticMesh")?.ResolvedObject?.GetPathName();
        if (mesh == null) return null;
        NeededMeshes.Add(mesh);

        // 9 floattia per instanssi binaarina. Naita on miljoonia: JSONina sama data
        // olisi kymmenia gigatavuja ja tuntien parsinta.
        var file = $"{level}_{slot}.f32";
        using (var bw = new BinaryWriter(File.Create(Path.Combine(_out, "foliage", file))))
        {
            foreach (var inst in data)
            {
                var t = inst.TransformData;
                var r = t.Rotation.Rotator();
                bw.Write(t.Translation.X); bw.Write(t.Translation.Y); bw.Write(t.Translation.Z);
                bw.Write(r.Pitch); bw.Write(r.Yaw); bw.Write(r.Roll);
                bw.Write(t.Scale3D.X); bw.Write(t.Scale3D.Y); bw.Write(t.Scale3D.Z);
            }
        }

        var (loc, rot, scale) = WorldTransform(ism);
        return new FoliageGroupRec
        {
            Mesh = mesh,
            Count = data.Length,
            File = file,
            // Instanssit ovat komponentin paikallisessa avaruudessa - Python lisaa taman.
            ComponentLoc = [loc.X, loc.Y, loc.Z],
            ComponentRot = [rot.Pitch, rot.Yaw, rot.Roll],
            ComponentScale = [scale.X, scale.Y, scale.Z],
        };
    }

    /// Komponentin maailmatransform AttachParent-ketjua pitkin. Cookatussa datassa
    /// actorin juurikomponentin relative == world, mutta kiinnitetyt alikomponentit
    /// (rakennusten osat) tarvitsevat taman summauksen.
    private static (FVector, FRotator, FVector) WorldTransform(UObject c)
    {
        var loc = c.GetOrDefault("RelativeLocation", FVector.ZeroVector);
        var rot = c.GetOrDefault("RelativeRotation", FRotator.ZeroRotator);
        var scale = c.GetOrDefault("RelativeScale3D", FVector.OneVector);

        var parentIdx = c.GetOrDefault<FPackageIndex>("AttachParent");
        var guard = 0;
        while (parentIdx is { IsNull: false } && guard++ < 16)
        {
            var parent = parentIdx.Load();
            if (parent == null) break;
            var ploc = parent.GetOrDefault("RelativeLocation", FVector.ZeroVector);
            var prot = parent.GetOrDefault("RelativeRotation", FRotator.ZeroRotator);
            var pscale = parent.GetOrDefault("RelativeScale3D", FVector.OneVector);

            loc = ploc + prot.RotateVector(loc * pscale);
            rot = new FRotator(rot.Pitch + prot.Pitch, rot.Yaw + prot.Yaw, rot.Roll + prot.Roll);
            scale *= pscale;
            parentIdx = parent.GetOrDefault<FPackageIndex>("AttachParent");
        }
        return (loc, rot, scale);
    }

    private static ActorTransformRec ReadActorTransform(UObject a, string level)
    {
        var src = a.GetOrDefault<FPackageIndex>("RootComponent")?.Load() ?? a;
        var loc = src.GetOrDefault("RelativeLocation", FVector.ZeroVector);
        var scale = src.GetOrDefault("RelativeScale3D", FVector.OneVector);
        return new ActorTransformRec
        {
            Level = level,
            Name = a.Name,
            Loc = [loc.X, loc.Y, loc.Z],
            Scale = [scale.X, scale.Y, scale.Z],
        };
    }

    // ---------------------------------------------------------------- meshien vienti

    /// Vie vain ne meshit jotka oikeasti esiintyvat kartalla. Koko pelin sisallon
    /// vienti olisi kymmenia gigatavuja, eika 99 % siita nay ylhaalta koskaan.
    private static async Task ExportMeshes(DefaultFileProvider provider, string dir, bool materials)
    {
        Directory.CreateDirectory(dir);
        var options = new ExportOptions(
            meshFormat: EMeshFormat.Gltf2,          // binaari .glb
            exportMaterials: materials,
            exportMorphTargets: false);

        var todo = new List<UStaticMesh>();
        // HLOD-paketit ovat yhdistettyja kaukokuvaproxyja joilla ei ole omaa
        // UStaticMesh-exporttia. Niiden yrittaminen tuottaa vain virheita.
        var names = NeededMeshes
            .Where(n => !n.Contains("/HLOD/", StringComparison.OrdinalIgnoreCase)
                        && !n.Contains("_HLOD", StringComparison.OrdinalIgnoreCase))
            .OrderBy(x => x).ToList();
        var skippedHlod = NeededMeshes.Count - names.Count;
        if (skippedHlod > 0)
            Console.WriteLine($"  ohitetaan {skippedHlod} HLOD-proxya");
        int ok = 0, skip = 0, fail = 0, extras = 0;
        Console.WriteLine($"Viedaan {names.Count} meshia -> {dir}");

        // Vienti eraissa: kaikkien kymmenientuhansien meshien pitaminen muistissa
        // yhta aikaa ei mahdu, ja eraittain ajettuna keskeytynyt ajo jatkuu helposti.
        const int batch = 250;
        foreach (var chunk in names.Chunk(batch))
        {
            todo.Clear();
            foreach (var path in chunk)
            {
                // Jo viedyt ohitetaan, jotta keskeytynyt ajo ei ala alusta.
                if (File.Exists(Path.Combine(dir, ExportRelativePath(path) + ".glb")))
                {
                    skip++;
                    continue;
                }
                try
                {
                    var mesh = provider.LoadPackageObject<UStaticMesh>(path.Split('.')[0]);
                    if (mesh != null) todo.Add(mesh);
                    else fail++;
                }
                catch (Exception e)
                {
                    if (fail < 10) Console.Error.WriteLine($"  {path}: {e.Message}");
                    fail++;
                }
            }

            if (todo.Count == 0) continue;

            var session = new ExportSession();
            var wanted = new HashSet<string>(todo.Select(m => m.GetPathName()),
                                             StringComparer.OrdinalIgnoreCase);
            foreach (var mesh in todo) session.Add(mesh);
            var results = await session.RunAsync(dir, options).ConfigureAwait(false);

            // Sessio vie mesheista ketjutetut materiaalit ja tekstuurit samalla,
            // joten tuloksia on enemman kuin meshia - lasketaan vain meshit.
            ok += results.Count(r => r.Success && wanted.Contains(r.ObjectPath));
            fail += results.Count(r => !r.Success && wanted.Contains(r.ObjectPath));
            extras += results.Count(r => !wanted.Contains(r.ObjectPath));
            Console.WriteLine($"  {ok + skip + fail}/{names.Count} meshia "
                              + $"(ok {ok}, oli jo {skip}, virhe {fail}, liitannaisia {extras})");
        }

        Console.WriteLine($"Meshit valmiit: {ok} vietu, {skip} oli jo, {fail} epaonnistui, "
                          + $"{extras} materiaalia ja tekstuuria mukana.");
    }

    /// '/Game/Foo/SM_Bar.SM_Bar' -> 'Game/Foo/SM_Bar' (sama polku jonne vienti kirjoittaa).
    private static string ExportRelativePath(string objectPath)
    {
        var p = objectPath.Split('.')[0].TrimStart('/');
        return p.Replace('/', Path.DirectorySeparatorChar);
    }


    // ---------------------------------------------------------------- layer-tekstuurit

    // Varitekstuurien tunnistus nimesta. Normaalikartta tai maski albedona pilaisi
    // koko maanpinnan varin, joten hylatyt painavat enemman kuin hyvaksytyt.
    private static readonly string[] AlbedoHints =
        ["_d", "_bc", "_alb", "albedo", "basecolor", "base_color", "diffuse", "_col", "_c"];
    private static readonly string[] RejectHints =
        ["_n", "_nrm", "normal", "_orm", "_rma", "_mask", "_ao", "rough", "_mt", "metal",
         "height", "_disp", "_spec", "_em", "emissive", "_opacity", "_packed"];

    /// Etsii jokaiselle landscape-layerille varitekstuurin koko pakin tiedostoindeksista.
    ///
    /// Materiaalin omat parametrit eivat riita: SCUMin layer-tekstuurit elavat
    /// materiaalifunktioiden sisalla, joten ylatason parametreista loytyi vain 4/26.
    /// Nimihaku koko indeksista loytaa loput, koska tekstuurit on nimetty kuvaavasti
    /// (Grass_Continental_LayerInfo -> T_Grass_Continental_D).
    private static int FindLayerTextures(DefaultFileProvider provider, string dir)
    {
        var compsPath = Path.Combine(_out, "landscape", "components.json");
        if (!File.Exists(compsPath))
        {
            Console.Error.WriteLine($"{compsPath} puuttuu - aja taysi purku ensin.");
            return 1;
        }

        var layers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var doc = JsonDocument.Parse(File.ReadAllText(compsPath)))
        {
            foreach (var comp in doc.RootElement.EnumerateArray())
            {
                if (!comp.TryGetProperty("Layers", out var arr)) continue;
                foreach (var alloc in arr.EnumerateArray())
                {
                    var name = alloc.GetProperty("Name").GetString();
                    if (!string.IsNullOrEmpty(name) && name != "None") layers.Add(name);
                }
            }
        }
        Console.WriteLine($"{layers.Count} layeria, haetaan tekstuurit {provider.Files.Count} tiedostosta...");

        // Esilaske jokaisen paketin nimi ja tokenit kerran - muuten 26 x 263k
        // merkkijonojen pilkkomista tehtaisiin uudestaan joka layerille.
        var candidates = provider.Files.Keys
            .Where(k => k.EndsWith(".uasset", StringComparison.OrdinalIgnoreCase))
            .Select(k => (Path: k,
                          Name: Path.GetFileNameWithoutExtension(k),
                          Tokens: Tokenize(Path.GetFileNameWithoutExtension(k))))
            .Where(c => c.Tokens.Count > 0 && IsAlbedoName(c.Name))
            .ToList();
        Console.WriteLine($"  {candidates.Count} varitekstuuriehdokasta");

        Directory.CreateDirectory(dir);
        var found = new Dictionary<string, string>();

        foreach (var layer in layers)
        {
            var wanted = Tokenize(layer.Replace("_LayerInfo", "", StringComparison.OrdinalIgnoreCase));
            if (wanted.Count == 0) continue;

            string? bestPath = null;
            var bestScore = 0.0;
            foreach (var cand in candidates)
            {
                var hits = wanted.Count(w => cand.Tokens.Contains(w));
                if (hits == 0) continue;

                var score = (double)hits / wanted.Count;
                // Landscape-poluissa olevat tekstuurit ovat lahes varmasti oikeita;
                // sama nimi voi esiintya myos esim. propsien tekstuureissa.
                if (cand.Path.Contains("Landscape", StringComparison.OrdinalIgnoreCase)
                    || cand.Path.Contains("Terrain", StringComparison.OrdinalIgnoreCase))
                    score += 0.25;
                if (score > bestScore)
                {
                    bestScore = score;
                    bestPath = cand.Path;
                }
            }

            if (bestPath == null || bestScore < 0.6)
            {
                Console.WriteLine($"  {layer,-36} ei osumaa");
                continue;
            }

            var file = DumpTextureByPath(provider, bestPath, dir);
            if (file == null)
            {
                Console.WriteLine($"  {layer,-36} {Path.GetFileNameWithoutExtension(bestPath)} (lataus epaonnistui)");
                continue;
            }

            found[layer] = file;
            Console.WriteLine($"  {layer,-36} {file} ({bestScore:0.00})");
        }

        WriteJson(Path.Combine(_out, "landscape", "layer_textures.json"), found);
        Console.WriteLine($"\n{found.Count}/{layers.Count} layeria sai tekstuurin -> {dir}");
        return 0;
    }

    private static string? DumpTextureByPath(DefaultFileProvider provider, string packagePath, string dir)
    {
        try
        {
            var tex = provider.LoadPackageObject<UTexture2D>(
                packagePath[..packagePath.LastIndexOf('.')]);
            if (tex == null) return null;

            var name = Sanitize(tex.Name);
            if (File.Exists(Path.Combine(dir, name + ".raw"))) return name;

            var bitmap = tex.Decode();
            if (bitmap == null) return null;

            File.WriteAllBytes(Path.Combine(dir, name + ".raw"), bitmap.Data);
            WriteJson(Path.Combine(dir, name + ".json"), new TextureMetaRec
            {
                Width = bitmap.Width,
                Height = bitmap.Height,
                PixelFormat = bitmap.PixelFormat.ToString(),
                Source = tex.GetPathName(),
            });
            return name;
        }
        catch
        {
            return null;
        }
    }

    private static HashSet<string> Tokenize(string name)
    {
        // Poistetaan tyyppi- ja numeroliitteet, jotta 'T_Grass_Continental_01_D' ja
        // 'Grass_Continental_LayerInfo' loytavat toisensa.
        string[] noise = ["t", "tex", "texture", "d", "bc", "n", "alb", "albedo",
                          "basecolor", "diffuse", "col", "c", "mi", "m", "landscape",
                          "land", "layer", "layerinfo", "info", "mat", "01", "02", "03"];
        var parts = name.Split(['_', '-', '.', ' '], StringSplitOptions.RemoveEmptyEntries);
        return parts
            .Select(p => p.ToLowerInvariant())
            .Where(p => p.Length > 1 && !noise.Contains(p) && !p.All(char.IsDigit))
            .ToHashSet();
    }

    private static bool IsAlbedoName(string name)
    {
        var low = name.ToLowerInvariant();
        if (RejectHints.Any(h => low.EndsWith(h) || low.Contains(h + "_"))) return false;
        return AlbedoHints.Any(h => low.EndsWith(h) || low.Contains(h + "_"));
    }

    // ---------------------------------------------------------------- apurit

    private static string? Arg(string[] a, string name)
    {
        var i = Array.IndexOf(a, name);
        return i >= 0 && i + 1 < a.Length ? a[i + 1] : null;
    }

    private static string ShortName(FPackageIndex? idx) =>
        idx == null || idx.IsNull ? "None" : idx.ResolvedObject?.Name.Text ?? "None";

    private static string Sanitize(string path)
    {
        var sb = new StringBuilder(path.Length);
        foreach (var ch in path)
            sb.Append(char.IsLetterOrDigit(ch) || ch is '_' or '-' ? ch : '_');
        return sb.ToString();
    }

    private static void WriteJson(string path, object o) =>
        File.WriteAllText(path, JsonSerializer.Serialize(o, Json));

    // ---------------------------------------------------------------- tietueet

    private sealed class LandscapeComponentRec
    {
        public string Level { get; set; } = "";
        public int SectionBaseX { get; set; }
        public int SectionBaseY { get; set; }
        public int ComponentSizeQuads { get; set; }
        public int SubsectionSizeQuads { get; set; }
        public int NumSubsections { get; set; }
        public string? Heightmap { get; set; }
        public float[] HeightmapScaleBias { get; set; } = [];
        public string?[] WeightmapTextures { get; set; } = [];
        public float[] WeightmapScaleBias { get; set; } = [];
        public LayerAllocRec[] Layers { get; set; } = [];
    }

    private sealed class LayerAllocRec
    {
        public string Name { get; set; } = "";
        public byte TextureIndex { get; set; }
        public byte Channel { get; set; }
    }

    private sealed class TextureMetaRec
    {
        public int Width { get; set; }
        public int Height { get; set; }
        public string PixelFormat { get; set; } = "";
        public string Source { get; set; } = "";
    }

    private sealed class StaticActorRec
    {
        public string Mesh { get; set; } = "";
        public float[] Loc { get; set; } = [];
        public float[] Rot { get; set; } = [];
        public float[] Scale { get; set; } = [];
    }

    private sealed class FoliageGroupRec
    {
        public string Mesh { get; set; } = "";
        public string File { get; set; } = "";
        public int Count { get; set; }
        public float[] ComponentLoc { get; set; } = [];
        public float[] ComponentRot { get; set; } = [];
        public float[] ComponentScale { get; set; } = [];
    }

    private sealed class ActorTransformRec
    {
        public string Level { get; set; } = "";
        public string Name { get; set; } = "";
        public float[] Loc { get; set; } = [];
        public float[] Scale { get; set; } = [];
    }

    private sealed class MaterialRec
    {
        public string Material { get; set; } = "";
        public MaterialTextureRec[] Textures { get; set; } = [];
        public MaterialScalarRec[] Scalars { get; set; } = [];
    }

    private sealed class MaterialTextureRec
    {
        public string Parameter { get; set; } = "";
        public string Texture { get; set; } = "";
        public string? File { get; set; }
    }

    private sealed class MaterialScalarRec
    {
        public string Parameter { get; set; } = "";
        public float Value { get; set; }
    }
}
