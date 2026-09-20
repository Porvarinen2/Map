// Vaihe A: purkaa SCUMin .pak-tiedostoista vain sen datan jota kartanteko tarvitsee.
//
// Miksi oma tyokalu eika pelkka FModel:
//   1) Landscapen heightmap/weightmap-tekstuurit on saatava ulos BITTITARKKOINA.
//      FModelin normaali PNG-vienti ajaa ne sRGB-muunnoksen lapi, jolloin 16-bittinen
//      korkeus (R*256+G) korruptoituu eika maasto tule ikina oikein.
//   2) Kasvillisuuden PerInstanceSMData on binaaridataa jota JSON-vienti ei anna.
//   3) Kaytto: kymmenettuhannet actorit halutaan tiiviina taulukkona, ei GB:n JSON-vuorena.
//
// Kaytto:
//   dotnet run -c Release -- --paks "C:\...\SCUM\Content\Paks" --aes 0x<avain> --out ..\..\..\dump
//
// HUOM CUE4Parse-API elaa: uudemmissa versioissa provider.Initialize() on Mount(),
// ja DefaultFileProvider-konstruktorista on poistunut isCaseInsensitive-parametri.
// Jos kaannos kaatuu naihin, korjaa nama kaksi kohtaa - muu koodi on vakaata.

using System.Text;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse.UE4.Assets.Exports.Component.StaticMesh;
using CUE4Parse.UE4.Assets.Exports.Texture;
using CUE4Parse.UE4.Assets.Objects;
using CUE4Parse.UE4.Objects.Core.Math;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Objects.UObject;
using CUE4Parse.UE4.Versions;
using Newtonsoft.Json;
using SkiaSharp;

namespace DumpWorld;

internal static class Program
{
    private static string _out = "dump";
    private static readonly HashSet<string> DumpedTextures = new();
    private static readonly HashSet<string> NeededMeshes = new();

    private static int Main(string[] args)
    {
        string paks = Arg(args, "--paks");
        string aes = Arg(args, "--aes") ?? "";
        _out = Arg(args, "--out") ?? "dump";
        string gameName = Arg(args, "--game") ?? "GAME_UE4_27";
        string filter = Arg(args, "--filter");   // esim. "Maps/" jos halutaan rajata

        if (paks == null)
        {
            Console.Error.WriteLine("Kaytto: --paks <polku> [--aes 0x..] [--out dump] [--game GAME_UE4_27] [--filter Maps/]");
            return 1;
        }

        if (!Enum.TryParse<EGame>(gameName, out var game))
        {
            Console.Error.WriteLine($"Tuntematon --game '{gameName}'. Katso CUE4Parse EGame-enum.");
            return 1;
        }

        Directory.CreateDirectory(_out);
        foreach (var sub in new[] { "textures", "actors", "foliage", "landscape" })
            Directory.CreateDirectory(Path.Combine(_out, sub));

        Console.WriteLine($"Avataan {paks} ({game})...");
        var provider = new DefaultFileProvider(paks, SearchOption.AllDirectories, false,
            new VersionContainer(game));
        provider.Initialize();                                   // uusi API: provider.Mount()
        if (!string.IsNullOrWhiteSpace(aes))
            provider.SubmitKey(new FGuid(), new FAesKey(aes));
        provider.LoadVirtualPaths();

        var maps = provider.Files.Keys
            .Where(k => k.EndsWith(".umap", StringComparison.OrdinalIgnoreCase))
            .Where(k => filter == null || k.Contains(filter, StringComparison.OrdinalIgnoreCase))
            .OrderBy(k => k)
            .ToList();
        Console.WriteLine($"{maps.Count} umap-pakettia kasiteltavana.");

        var landscape = new List<LandscapeComponentRec>();
        var landscapeActors = new List<ActorTransformRec>();
        int done = 0;

        foreach (var map in maps)
        {
            var levelName = Sanitize(Path.GetFileNameWithoutExtension(map));
            List<UObject> exports;
            try
            {
                exports = provider.LoadAllObjects(map).ToList();
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
                        landscape.Add(ReadLandscapeComponent(export, provider, levelName));
                        break;

                    case "Landscape":
                    case "LandscapeStreamingProxy":
                        landscapeActors.Add(ReadActorTransform(export, levelName));
                        break;
                }

                // Kasvillisuus ennen tavallisia meshkomponentteja: HISM peria SMC:n.
                if (export is UInstancedStaticMeshComponent ism)
                {
                    var rec = ReadFoliage(ism, levelName, foliage.Count);
                    if (rec != null) foliage.Add(rec);
                    continue;
                }

                if (export.ExportType is "StaticMeshComponent" or "StaticMeshComponent0")
                {
                    var rec = ReadStaticMesh(export);
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

        // Lista meshista jotka oikeasti nakyvat kartalla -> FModelissa viedaan vain nama,
        // ei koko pelin sisaltoa.
        File.WriteAllLines(Path.Combine(_out, "meshes_needed.txt"), NeededMeshes.OrderBy(x => x));

        Console.WriteLine($"Valmis. {landscape.Count} landscape-komponenttia, "
                          + $"{DumpedTextures.Count} tekstuuria, {NeededMeshes.Count} uniikkia meshia.");
        Console.WriteLine($"Seuraavaksi: vie dump/meshes_needed.txt:n meshit FModelista glTF:na kansioon assets/meshes.");
        return 0;
    }

    // ---------------------------------------------------------------- landscape

    private static LandscapeComponentRec ReadLandscapeComponent(UObject c, DefaultFileProvider p, string level)
    {
        var rec = new LandscapeComponentRec
        {
            Level = level,
            SectionBaseX = c.GetOrDefault("SectionBaseX", 0),
            SectionBaseY = c.GetOrDefault("SectionBaseY", 0),
            ComponentSizeQuads = c.GetOrDefault("ComponentSizeQuads", 63),
            SubsectionSizeQuads = c.GetOrDefault("SubsectionSizeQuads", 63),
            NumSubsections = c.GetOrDefault("NumSubsections", 1),
        };

        var hsb = c.GetOrDefault("HeightmapScaleBias", new FVector4(0, 0, 0, 0));
        rec.HeightmapScaleBias = new[] { hsb.X, hsb.Y, hsb.Z, hsb.W };
        rec.Heightmap = DumpTexture(c.GetOrDefault<FPackageIndex>("HeightmapTexture"));

        var wsb = c.GetOrDefault("WeightmapScaleBias", new FVector4(0, 0, 0, 0));
        rec.WeightmapScaleBias = new[] { wsb.X, wsb.Y, wsb.Z, wsb.W };

        var wtex = c.GetOrDefault<FPackageIndex[]>("WeightmapTextures") ?? Array.Empty<FPackageIndex>();
        rec.WeightmapTextures = wtex.Select(DumpTexture).ToArray();

        var allocs = c.GetOrDefault<FStructFallback[]>("WeightmapLayerAllocations")
                     ?? Array.Empty<FStructFallback>();
        rec.Layers = allocs.Select(a => new LayerAllocRec
        {
            Name = ShortName(a.GetOrDefault<FPackageIndex>("LayerInfo")),
            TextureIndex = a.GetOrDefault("WeightmapTextureIndex", (byte)0),
            Channel = a.GetOrDefault("WeightmapTextureChannel", (byte)0),
        }).ToArray();

        return rec;
    }

    /// Kirjoittaa tekstuurin RAAKANA RGBA8:na. Ei PNG:ta, ei sRGB:ta, ei pakkausta -
    /// tama on koko heightmap-purun ydin.
    private static string DumpTexture(FPackageIndex idx)
    {
        if (idx == null || idx.IsNull) return null;
        var tex = idx.Load<UTexture2D>();
        if (tex == null) return null;

        var key = Sanitize(tex.GetPathName());
        if (DumpedTextures.Contains(key)) return key;

        SKBitmap bmp;
        try { bmp = tex.Decode(); }
        catch (Exception e) { Console.Error.WriteLine($"  tekstuuri {key}: {e.Message}"); return null; }
        if (bmp == null) return null;

        using (bmp)
        using (var rgba = bmp.ColorType == SKColorType.Rgba8888 ? bmp.Copy() : bmp.Copy(SKColorType.Rgba8888))
        {
            File.WriteAllBytes(Path.Combine(_out, "textures", key + ".raw"), rgba.Bytes);
            WriteJson(Path.Combine(_out, "textures", key + ".json"), new
            {
                width = rgba.Width,
                height = rgba.Height,
                format = "RGBA8",
                source = tex.GetPathName(),
            });
        }

        DumpedTextures.Add(key);
        return key;
    }

    // ---------------------------------------------------------------- actorit

    private static StaticActorRec ReadStaticMesh(UObject c)
    {
        var meshIdx = c.GetOrDefault<FPackageIndex>("StaticMesh");
        if (meshIdx == null || meshIdx.IsNull) return null;
        var mesh = meshIdx.ResolvedObject?.GetPathName();
        if (mesh == null) return null;
        NeededMeshes.Add(mesh);

        var (loc, rot, scale) = WorldTransform(c);
        return new StaticActorRec
        {
            Mesh = mesh,
            Loc = new[] { loc.X, loc.Y, loc.Z },
            Rot = new[] { rot.Pitch, rot.Yaw, rot.Roll },
            Scale = new[] { scale.X, scale.Y, scale.Z },
        };
    }

    private static FoliageGroupRec ReadFoliage(UInstancedStaticMeshComponent ism, string level, int slot)
    {
        var data = ism.PerInstanceSMData;
        if (data == null || data.Length == 0) return null;

        var meshIdx = ism.GetOrDefault<FPackageIndex>("StaticMesh");
        var mesh = meshIdx?.ResolvedObject?.GetPathName();
        if (mesh == null) return null;
        NeededMeshes.Add(mesh);

        // 9 floattia per instanssi: sijainti, rotaatio, skaala. Binaarina koska
        // naita on miljoonia - JSON olisi kymmenia gigatavuja ja tuntien parsinta.
        var file = $"{level}_{slot}.f32";
        using (var fs = File.Create(Path.Combine(_out, "foliage", file)))
        using (var bw = new BinaryWriter(fs))
        {
            foreach (var inst in data)
            {
                var m = inst.TransformData;
                var o = m.GetOrigin();
                var r = m.Rotator();
                var s = m.GetScaleVector();
                bw.Write(o.X); bw.Write(o.Y); bw.Write(o.Z);
                bw.Write(r.Pitch); bw.Write(r.Yaw); bw.Write(r.Roll);
                bw.Write(s.X); bw.Write(s.Y); bw.Write(s.Z);
            }
        }

        var (loc, rot, scale) = WorldTransform(ism);
        return new FoliageGroupRec
        {
            Mesh = mesh,
            Count = data.Length,
            File = file,
            // Instanssit ovat komponentin paikallisessa avaruudessa - Python lisaa taman.
            ComponentLoc = new[] { loc.X, loc.Y, loc.Z },
            ComponentRot = new[] { rot.Pitch, rot.Yaw, rot.Roll },
            ComponentScale = new[] { scale.X, scale.Y, scale.Z },
        };
    }

    /// Kerää komponentin maailmatransformin kulkemalla AttachParent-ketju juureen.
    /// Cookatussa datassa actorin juurikomponentin relative == world, mutta kiinnitetyt
    /// alikomponentit (esim. rakennusten osat) tarvitsevat taman summauksen.
    private static (FVector, FRotator, FVector) WorldTransform(UObject c)
    {
        var loc = c.GetOrDefault("RelativeLocation", FVector.ZeroVector);
        var rot = c.GetOrDefault("RelativeRotation", FRotator.ZeroRotator);
        var scale = c.GetOrDefault("RelativeScale3D", FVector.OneVector);

        var parentIdx = c.GetOrDefault<FPackageIndex>("AttachParent");
        int guard = 0;
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
        var root = a.GetOrDefault<FPackageIndex>("RootComponent")?.Load();
        var src = root ?? a;
        var loc = src.GetOrDefault("RelativeLocation", FVector.ZeroVector);
        var scale = src.GetOrDefault("RelativeScale3D", FVector.OneVector);
        return new ActorTransformRec
        {
            Level = level,
            Name = a.Name,
            Loc = new[] { loc.X, loc.Y, loc.Z },
            Scale = new[] { scale.X, scale.Y, scale.Z },
        };
    }

    // ---------------------------------------------------------------- apurit

    private static string Arg(string[] a, string name)
    {
        var i = Array.IndexOf(a, name);
        return i >= 0 && i + 1 < a.Length ? a[i + 1] : null;
    }

    private static string ShortName(FPackageIndex idx) =>
        idx == null || idx.IsNull ? "None" : idx.ResolvedObject?.Name.Text ?? "None";

    private static string Sanitize(string path)
    {
        var sb = new StringBuilder(path.Length);
        foreach (var ch in path)
            sb.Append(char.IsLetterOrDigit(ch) || ch is '_' or '-' ? ch : '_');
        return sb.ToString();
    }

    private static void WriteJson(string path, object o) =>
        File.WriteAllText(path, JsonConvert.SerializeObject(o, Formatting.Indented));

    // ---------------------------------------------------------------- tietueet

    private sealed class LandscapeComponentRec
    {
        public string Level;
        public int SectionBaseX, SectionBaseY;
        public int ComponentSizeQuads, SubsectionSizeQuads, NumSubsections;
        public string Heightmap;
        public float[] HeightmapScaleBias;
        public string[] WeightmapTextures;
        public float[] WeightmapScaleBias;
        public LayerAllocRec[] Layers;
    }

    private sealed class LayerAllocRec
    {
        public string Name;
        public byte TextureIndex, Channel;
    }

    private sealed class StaticActorRec
    {
        public string Mesh;
        public float[] Loc, Rot, Scale;
    }

    private sealed class FoliageGroupRec
    {
        public string Mesh, File;
        public int Count;
        public float[] ComponentLoc, ComponentRot, ComponentScale;
    }

    private sealed class ActorTransformRec
    {
        public string Level, Name;
        public float[] Loc, Scale;
    }
}
