using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Muna.Core;

/// <summary>The link of Muna Phone (the Android app), as linux/src/phone/phoneLink.js: the app's server,
/// started on the phone with adb's rights, dials the computer twice, C for the control lines and V for
/// the raw H.264 picture. The secret is never sent; each side proves it knows it:
///   phone    HELLO2 &lt;role&gt; &lt;fingerprint of the secret&gt; &lt;nonce P&gt;
///   computer CHAL &lt;nonce C&gt; &lt;HMAC(secret, "srv|P|C")&gt;
///   phone    AUTH &lt;HMAC(secret, "cli|C|P")&gt; &lt;screen&gt; &lt;sdk&gt; &lt;model&gt;
///   computer OK</summary>
public static class PhoneLinkProtocol
{
    public const string AppId = "dev.muna.phone";
    public const string ServerClass = "dev.muna.phone.server.Server";

    static string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();

    public static string Fingerprint(string token) => Hex(SHA256.HashData(Encoding.UTF8.GetBytes(token)))[..8];

    public static string Proof(string token, string who, string first, string second) =>
        Hex(HMACSHA256.HashData(Encoding.UTF8.GetBytes(token), Encoding.UTF8.GetBytes($"{who}|{first}|{second}")));

    public static string RandomToken() => Hex(RandomNumberGenerator.GetBytes(16));

    /// <summary>Reads one line without reading past it (the picture follows on V).</summary>
    public static async Task<string?> ReadLine(Stream stream, CancellationToken cancel)
    {
        var bytes = new List<byte>();
        var one = new byte[1];
        while (true)
        {
            var n = await stream.ReadAsync(one, cancel);
            if (n <= 0) return null;
            if (one[0] == '\n') break;
            if (bytes.Count > 4096) return null;
            bytes.Add(one[0]);
        }
        return Encoding.UTF8.GetString(bytes.ToArray()).TrimEnd('\r');
    }

    static async Task Write(Stream stream, string line, CancellationToken cancel)
    {
        await stream.WriteAsync(Encoding.UTF8.GetBytes(line + "\n"), cancel);
        await stream.FlushAsync(cancel);
    }

    /// <summary>The computer's side of one connection: the role ('C' or 'V') and what the phone told
    /// about itself, or null when it is not the phone with <paramref name="token"/> (answered NO).</summary>
    public static async Task<(char Role, string Info)?> Accept(Stream stream, string token, CancellationToken cancel)
    {
        var hello = (await ReadLine(stream, cancel))?.Split(' ');
        if (hello is null) return null;
        async Task<(char, string)?> Refuse()
        {
            try { await Write(stream, "NO", cancel); } catch { /* gone */ }
            return null;
        }
        if (hello.Length == 0) return await Refuse();
        if (hello[0] == "HELLO" && hello.Length >= 3 && hello[2] == token && hello[1] is "C" or "V")
        {
            // the first version of the protocol: the token itself
            await Write(stream, "OK", cancel);
            return (hello[1][0], string.Join(' ', hello.Skip(3)));
        }
        if (hello.Length != 4 || hello[0] != "HELLO2" || hello[1] is not ("C" or "V") || hello[2] != Fingerprint(token) || !Regex.IsMatch(hello[3], "^[0-9a-f]{16,64}$"))
            return await Refuse();
        var nonce = RandomToken();
        await Write(stream, $"CHAL {nonce} {Proof(token, "srv", hello[3], nonce)}", cancel);
        var auth = (await ReadLine(stream, cancel))?.Split(' ');
        if (auth is null || auth.Length < 2 || auth[0] != "AUTH" ||
            !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(auth[1]), Encoding.UTF8.GetBytes(Proof(token, "cli", nonce, hello[3]))))
            return await Refuse();
        await Write(stream, "OK", cancel);
        return (hello[1][0], string.Join(' ', auth.Skip(2)));
    }

    /// <summary>The phone's side (what Muna Phone does; for the tests).</summary>
    public static async Task<bool> Dial(Stream stream, string token, char role, string info, CancellationToken cancel)
    {
        var mine = RandomToken();
        await Write(stream, $"HELLO2 {role} {Fingerprint(token)} {mine}", cancel);
        var challenge = (await ReadLine(stream, cancel))?.Split(' ');
        if (challenge is not { Length: 3 } || challenge[0] != "CHAL" || challenge[2] != Proof(token, "srv", mine, challenge[1])) return false;
        await Write(stream, $"AUTH {Proof(token, "cli", challenge[1], mine)} {info}", cancel);
        return await ReadLine(stream, cancel) == "OK";
    }

    /// <summary>Every "inet 192.168.0.15/24" of `ip -4 addr show`.</summary>
    public static List<(IPAddress Address, int Prefix)> AddressesOf(string text) =>
        Regex.Matches(text, @"inet (\d+\.\d+\.\d+\.\d+)/(\d+)").Select(m => (IPAddress.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value))).ToList();

    static uint Number(IPAddress ip)
    {
        var b = ip.GetAddressBytes();
        return (uint)(b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]);
    }

    /// <summary>The address of this computer the phone can reach: the one in the same network as one of the phone's.</summary>
    public static string? LanAddress(string phoneAddresses, IEnumerable<(IPAddress Address, int Prefix)> local)
    {
        var phone = AddressesOf(phoneAddresses);
        foreach (var (address, prefix) in local)
        {
            if (address.AddressFamily != AddressFamily.InterNetwork || address.GetAddressBytes()[0] == 127) continue;
            foreach (var (other, otherPrefix) in phone)
            {
                var p = Math.Min(prefix, otherPrefix);
                if (p < 8 || other.GetAddressBytes()[0] == 127) continue;
                var mask = p >= 32 ? uint.MaxValue : ~(uint.MaxValue >> p);
                if ((Number(address) & mask) == (Number(other) & mask)) return address.ToString();
            }
        }
        return null;
    }
}
