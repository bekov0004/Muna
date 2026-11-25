using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json.Nodes;

namespace Muna.Core;

/// <summary>LocalSend as Muna speaks it (shared/protocols/localsend.md).</summary>
public static class LocalSend
{
    public const int Port = 53317;
    public const string ApiPath = "/api/localsend/v2";
    public const string MulticastAddress = "224.0.0.167";
    public const string ProtocolVersion = "2.0";
    /// <summary>Every Muna says this model; that is how Munas know each other.</summary>
    public const string MunaModel = "Muna";
    public const int MaxIncomingFiles = 500;
    public static readonly TimeSpan AskTimeout = TimeSpan.FromSeconds(60);
}

/// <summary>What a device says about itself (/info, /register, announcements).</summary>
public sealed class DeviceInfo
{
    public string Alias { get; set; } = "";
    public string Version { get; set; } = LocalSend.ProtocolVersion;
    public string DeviceModel { get; set; } = LocalSend.MunaModel;
    public string DeviceType { get; set; } = "desktop";
    public string Fingerprint { get; set; } = "";
    public int Port { get; set; } = LocalSend.Port;
    public string Protocol { get; set; } = "https";
    public bool Download { get; set; }
    public bool? Announce { get; set; }

    public JsonObject ToJson()
    {
        var o = new JsonObject
        {
            ["alias"] = Alias, ["version"] = Version, ["deviceModel"] = DeviceModel, ["deviceType"] = DeviceType,
            ["fingerprint"] = Fingerprint, ["port"] = Port, ["protocol"] = Protocol, ["download"] = Download,
        };
        if (Announce is bool a) o["announce"] = a;
        return o;
    }

    /// <summary>Null when it is not LocalSend's answer (no alias).</summary>
    public static DeviceInfo? From(JsonNode? node)
    {
        var alias = node.Str("alias");
        if (alias is null) return null;
        return new DeviceInfo
        {
            Alias = alias, Version = node.Str("version") ?? "", DeviceModel = node.Str("deviceModel") ?? "",
            DeviceType = node.Str("deviceType") ?? "desktop", Fingerprint = node.Str("fingerprint") ?? "",
            Port = (int)(node.Long("port") ?? LocalSend.Port), Protocol = node.Str("protocol") ?? "https",
            Download = node.Bool("download") ?? false, Announce = node.Bool("announce"),
        };
    }
}

/// <summary>A device found on the network.</summary>
public sealed record Device(string Ip, int Port, string Protocol, string Alias, string DeviceModel, string DeviceType, string Fingerprint)
{
    public static Device From(string ip, int port, string protocol, DeviceInfo info) =>
        new(ip, port, protocol, info.Alias, info.DeviceModel, info.DeviceType, info.Fingerprint);

    /// <summary>Tells devices apart: by the fingerprint (it survives a new address), else by where they are.</summary>
    public string Key => string.IsNullOrEmpty(Fingerprint) ? $"{Ip}:{Port}" : Fingerprint;
    public bool IsMuna => DeviceModel == LocalSend.MunaModel;

    /// <summary>Whether this is that saved group member: same fingerprint, else same name.</summary>
    public bool IsMember(GroupMember member) =>
        (member.Fingerprint.Length > 0 && Fingerprint == member.Fingerprint) || (member.Alias.Length > 0 && Alias == member.Alias);

    public GroupMember AsMember => new(Fingerprint, Alias, DeviceModel, DeviceType);

    /// <summary>Other Munas first, then by name.</summary>
    public static List<Device> Sorted(IEnumerable<Device> devices) =>
        devices.OrderBy(d => d.IsMuna ? 0 : 1).ThenBy(d => d.Alias, StringComparer.CurrentCultureIgnoreCase).ToList();
}

public sealed record GroupMember(string Fingerprint, string Alias, string DeviceModel = "", string DeviceType = "desktop")
{
    public static GroupMember Clean(string? fingerprint, string? alias, string? model, string? type) =>
        new(Json.Cut(fingerprint ?? "", 128), Json.Cut(alias ?? "", 100), Json.Cut(model ?? "", 50), Json.Cut(type ?? "desktop", 20));
}

public sealed record DeviceGroup(string Id, string Name, List<GroupMember> Members)
{
    /// <summary>The group's members on the network now, and the others.</summary>
    public (List<Device> Found, List<GroupMember> Missing) Presence(IReadOnlyList<Device> devices)
    {
        var found = new List<Device>();
        var missing = new List<GroupMember>();
        foreach (var member in Members)
        {
            var device = devices.FirstOrDefault(d => d.IsMember(member));
            if (device is null) missing.Add(member); else found.Add(device);
        }
        return (found, missing);
    }
}

public sealed class GroupException(string message) : Exception(message);

/// <summary>The saved groups (localsend-groups.json), with the same rules as Muna on Linux.</summary>
public sealed class GroupsStore
{
    public const int MaxGroups = 50;
    public const int MaxMembers = 200;
    public const int MaxNameLength = 60;
    readonly JsonStore _store;
    public List<DeviceGroup> Groups { get; private set; } = new();

    public GroupsStore(JsonStore? store = null)
    {
        _store = store ?? new JsonStore("localsend-groups.json");
        foreach (var node in _store.Load().Arr("groups") ?? new JsonArray())
        {
            var id = node.Str("id");
            var name = node.Str("name");
            var members = node.Arr("members");
            if (id is null || name is null || members is null) continue;
            Groups.Add(new DeviceGroup(id, name, members.Select(m =>
                GroupMember.Clean(m.Str("fingerprint"), m.Str("alias"), m.Str("deviceModel"), m.Str("deviceType"))).ToList()));
        }
    }

    /// <summary>Saves a group (a new one when id is null); a group with the same name (any case) is replaced.</summary>
    public DeviceGroup Save(string? id, string name, IEnumerable<GroupMember> members)
    {
        name = Json.Cut(name.Trim(), MaxNameLength);
        if (name.Length == 0) throw new GroupException("A group needs a name");
        var clean = members.Take(MaxMembers).Where(m => m.Fingerprint.Length > 0 || m.Alias.Length > 0).ToList();
        if (clean.Count == 0) throw new GroupException("A group needs at least one device");
        var lowered = name.ToLowerInvariant();
        var others = Groups.Where(g => g.Id != id && g.Name.ToLowerInvariant() != lowered).ToList();
        if (others.Count >= MaxGroups) throw new GroupException($"At most {MaxGroups} groups");
        var group = new DeviceGroup(id ?? NewId(), name, clean);
        var at = Groups.FindIndex(g => g.Id == id || g.Name.ToLowerInvariant() == lowered);
        others.Insert(at < 0 ? others.Count : Math.Min(at, others.Count), group);
        Groups = others;
        Persist();
        return group;
    }

    public void Delete(string id)
    {
        if (Groups.RemoveAll(g => g.Id == id) > 0) Persist();
    }

    static string NewId() =>
        "g" + ToBase36(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) + ToBase36(Random.Shared.Next(1296));

    static string ToBase36(long value)
    {
        const string digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        var text = "";
        do { text = digits[(int)(value % 36)] + text; value /= 36; } while (value > 0);
        return text;
    }

    void Persist()
    {
        var array = new JsonArray();
        foreach (var g in Groups)
        {
            var members = new JsonArray();
            foreach (var m in g.Members)
                members.Add(new JsonObject { ["fingerprint"] = m.Fingerprint, ["alias"] = m.Alias, ["deviceModel"] = m.DeviceModel, ["deviceType"] = m.DeviceType });
            array.Add(new JsonObject { ["id"] = g.Id, ["name"] = g.Name, ["members"] = members });
        }
        _store.Save(new JsonObject { ["version"] = 1, ["groups"] = array });
    }
}

/// <summary>Received file names: safe (no path parts) and free (a (1).pdf, a (2).pdf …).</summary>
public static class ReceivedFileNames
{
    public static string Safe(string name)
    {
        var last = name.Split('/', '\\').LastOrDefault(p => true) ?? "";
        var cleaned = new string(last.Where(c => c >= ' ').ToArray()).Trim();
        if (cleaned.Length == 0 || cleaned == "." || cleaned == "..") return "file";
        return cleaned.StartsWith('.') ? "_" + cleaned.TrimStart('.') : cleaned;
    }

    public static string Free(string folder, string name, Func<string, bool>? exists = null)
    {
        exists ??= p => File.Exists(p) || Directory.Exists(p);
        var dot = name.LastIndexOf('.');
        var (stem, ext) = dot > 0 ? (name[..dot], name[dot..]) : (name, "");
        for (var i = 0; i < 1000; i++)
        {
            var candidate = Path.Combine(folder, i == 0 ? name : $"{stem} ({i}){ext}");
            if (!exists(candidate)) return candidate;
        }
        return Path.Combine(folder, Guid.NewGuid().ToString("N") + ext);
    }
}

/// <summary>Muna's own certificate for LocalSend: self-signed, made once, kept with Muna's data.
/// Its SHA-256 is this device's fingerprint (shared/protocols/localsend.md).</summary>
public static class LocalSendCertificate
{
    public static X509Certificate2 LoadOrCreate(string? folder = null)
    {
        var path = Path.Combine(folder ?? DataDirectory.Path, "localsend.pfx");
        if (File.Exists(path))
        {
            try { return X509CertificateLoader.LoadPkcs12FromFile(path, "muna", X509KeyStorageFlags.Exportable); }
            catch { /* broken: make a new one */ }
        }
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Muna", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var made = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(100));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, made.Export(X509ContentType.Pfx, "muna"));
        return X509CertificateLoader.LoadPkcs12FromFile(path, "muna", X509KeyStorageFlags.Exportable);
    }

    public static string Fingerprint(X509Certificate2 certificate) =>
        Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant();
}
