namespace Muna.Core;

/// <summary>A small QR code encoder, the port of linux/src/utils/qr.js: byte mode, error correction
/// level M, versions 1 to 10 (up to 213 bytes). <see cref="Encode"/> gives the modules, true = dark,
/// with no quiet zone.</summary>
public static class Qr
{
    static readonly int[] Total = { 26, 44, 70, 100, 134, 172, 196, 242, 292, 346 };
    static readonly int[] EcPerBlock = { 10, 16, 26, 18, 24, 16, 18, 22, 22, 26 };
    static readonly int[] Blocks = { 1, 1, 1, 2, 2, 4, 4, 4, 5, 5 };
    static readonly int[][] Align =
    {
        System.Array.Empty<int>(), new[] { 6, 18 }, new[] { 6, 22 }, new[] { 6, 26 }, new[] { 6, 30 }, new[] { 6, 34 },
        new[] { 6, 22, 38 }, new[] { 6, 24, 42 }, new[] { 6, 26, 46 }, new[] { 6, 28, 50 },
    };
    static readonly int[] Exp = new int[512];
    static readonly int[] Log = new int[256];

    static Qr()
    {
        var x = 1;
        for (var i = 0; i < 255; i++)
        {
            Exp[i] = x;
            Log[x] = i;
            x <<= 1;
            if ((x & 0x100) != 0) x ^= 0x11D;
        }
        for (var i = 255; i < 512; i++) Exp[i] = Exp[i - 255];
    }

    static int DataCodewords(int v) => Total[v - 1] - EcPerBlock[v - 1] * Blocks[v - 1];
    static int Mul(int a, int b) => a == 0 || b == 0 ? 0 : Exp[Log[a] + Log[b]];

    static int[] Generator(int degree)
    {
        var poly = new List<int> { 1 };
        for (var i = 0; i < degree; i++)
        {
            var next = new int[poly.Count + 1];
            for (var j = 0; j < poly.Count; j++)
            {
                next[j] ^= poly[j];
                next[j + 1] ^= Mul(poly[j], Exp[i]);
            }
            poly = next.ToList();
        }
        return poly.ToArray();
    }

    static List<int> Remainder(List<int> data, int degree)
    {
        var gen = Generator(degree);
        var result = new List<int>(new int[degree]);
        foreach (var b in data)
        {
            var factor = b ^ result[0];
            result.RemoveAt(0);
            result.Add(0);
            for (var i = 0; i < degree; i++) result[i] ^= Mul(gen[i + 1], factor);
        }
        return result;
    }

    static List<int> BitsFor(byte[] bytes, int version)
    {
        var bits = new List<int>();
        void Push(int value, int count)
        {
            for (var i = count - 1; i >= 0; i--) bits.Add((value >>> i) & 1);
        }
        Push(0b0100, 4);
        Push(bytes.Length, version < 10 ? 8 : 16);
        foreach (var b in bytes) Push(b, 8);
        var capacity = DataCodewords(version) * 8;
        Push(0, Math.Min(4, capacity - bits.Count));
        while (bits.Count % 8 != 0) bits.Add(0);
        for (var pad = 0xEC; bits.Count < capacity; pad ^= 0xEC ^ 0x11) Push(pad, 8);
        var codewords = new List<int>();
        for (var i = 0; i < bits.Count; i += 8)
        {
            var value = 0;
            for (var j = 0; j < 8; j++) value = (value << 1) | bits[i + j];
            codewords.Add(value);
        }
        return codewords;
    }

    static List<int> Interleave(List<int> data, int version)
    {
        int blocks = Blocks[version - 1], ec = EcPerBlock[version - 1], total = Total[version - 1];
        var shortCount = blocks - total % blocks;
        var shortLen = total / blocks;
        var dataBlocks = new List<List<int>>();
        var ecBlocks = new List<List<int>>();
        var at = 0;
        for (var i = 0; i < blocks; i++)
        {
            var len = shortLen - ec + (i < shortCount ? 0 : 1);
            var part = data.Skip(at).Take(len).ToList();
            at += len;
            dataBlocks.Add(part);
            ecBlocks.Add(Remainder(part, ec));
        }
        var output = new List<int>();
        var longest = dataBlocks.Max(b => b.Count);
        for (var i = 0; i < longest; i++)
            foreach (var b in dataBlocks) if (i < b.Count) output.Add(b[i]);
        for (var i = 0; i < ec; i++)
            foreach (var b in ecBlocks) output.Add(b[i]);
        return output;
    }

    static int Bch(int value, int poly, int bitsTotal, int bitsData)
    {
        var rem = value << (bitsTotal - bitsData);
        for (var i = bitsTotal - 1; i >= bitsTotal - bitsData; i--)
            if (((rem >>> i) & 1) != 0) rem ^= poly << (i - (bitsTotal - bitsData));
        return (value << (bitsTotal - bitsData)) | rem;
    }

    static readonly Func<int, int, bool>[] Masks =
    {
        (x, y) => (x + y) % 2 == 0,
        (x, y) => y % 2 == 0,
        (x, y) => x % 3 == 0,
        (x, y) => (x + y) % 3 == 0,
        (x, y) => (y / 2 + x / 3) % 2 == 0,
        (x, y) => x * y % 2 + x * y % 3 == 0,
        (x, y) => (x * y % 2 + x * y % 3) % 2 == 0,
        (x, y) => ((x + y) % 2 + x * y % 3) % 2 == 0,
    };

    static bool[,] Build(List<int> codewords, int version, int mask)
    {
        var size = version * 4 + 17;
        var dark = new bool[size, size];    // [y, x]
        var fixd = new bool[size, size];
        void Set(int x, int y, bool value) { dark[y, x] = value; fixd[y, x] = true; }
        for (var i = 0; i < size; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
        void Finder(int cx, int cy)
        {
            for (var dy = -4; dy <= 4; dy++)
                for (var dx = -4; dx <= 4; dx++)
                {
                    int x = cx + dx, y = cy + dy;
                    if (x < 0 || y < 0 || x >= size || y >= size) continue;
                    var d = Math.Max(Math.Abs(dx), Math.Abs(dy));
                    Set(x, y, d != 2 && d != 4);
                }
        }
        Finder(3, 3);
        Finder(size - 4, 3);
        Finder(3, size - 4);
        var pos = Align[version - 1];
        foreach (var cy in pos)
            foreach (var cx in pos)
            {
                if ((cx == 6 && cy == 6) || (cx == 6 && cy == size - 7) || (cx == size - 7 && cy == 6)) continue;
                for (var dy = -2; dy <= 2; dy++)
                    for (var dx = -2; dx <= 2; dx++) Set(cx + dx, cy + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
            }
        for (var i = 0; i < 9; i++) { fixd[8, i] = true; fixd[i, 8] = true; }
        for (var i = 0; i < 8; i++) { fixd[8, size - 1 - i] = true; fixd[size - 1 - i, 8] = true; }
        if (version >= 7)
            for (var i = 0; i < 6; i++)
                for (var j = 0; j < 3; j++) { fixd[size - 11 + j, i] = true; fixd[i, size - 11 + j] = true; }
        Set(8, size - 8, true);
        var bits = new List<int>();
        foreach (var cw in codewords)
            for (var i = 7; i >= 0; i--) bits.Add((cw >>> i) & 1);
        var bit = 0;
        for (var right = size - 1; right >= 1; right -= 2)
        {
            if (right == 6) right = 5;
            for (var v = 0; v < size; v++)
                for (var j = 0; j < 2; j++)
                {
                    var x = right - j;
                    var upward = ((right + 1) & 2) == 0;
                    var y = upward ? size - 1 - v : v;
                    if (fixd[y, x]) continue;
                    var value = bit < bits.Count && bits[bit] == 1;
                    bit++;
                    if (Masks[mask](x, y)) value = !value;
                    dark[y, x] = value;
                }
        }
        var format = Bch((0b00 << 3) | mask, 0x537, 15, 5) ^ 0x5412;
        bool F(int i) => ((format >>> i) & 1) == 1;
        for (var i = 0; i <= 5; i++) dark[i, 8] = F(i);
        dark[7, 8] = F(6);
        dark[8, 8] = F(7);
        dark[8, 7] = F(8);
        for (var i = 9; i < 15; i++) dark[8, 14 - i] = F(i);
        for (var i = 0; i < 8; i++) dark[8, size - 1 - i] = F(i);
        for (var i = 8; i < 15; i++) dark[size - 15 + i, 8] = F(i);
        dark[size - 8, 8] = true;
        if (version >= 7)
        {
            var info = Bch(version, 0x1F25, 18, 6);
            for (var i = 0; i < 18; i++)
            {
                var on = ((info >>> i) & 1) == 1;
                int a = size - 11 + i % 3, b = i / 3;
                dark[b, a] = on;
                dark[a, b] = on;
            }
        }
        return dark;
    }

    static int Penalty(bool[,] dark)
    {
        var size = dark.GetLength(0);
        var score = 0;
        for (var y = 0; y < size; y++)
        {
            var run = 1;
            for (var x = 1; x < size; x++)
            {
                run = dark[y, x] == dark[y, x - 1] ? run + 1 : 1;
                if (run == 5) score += 3; else if (run > 5) score++;
            }
        }
        for (var x = 0; x < size; x++)
        {
            var run = 1;
            for (var y = 1; y < size; y++)
            {
                run = dark[y, x] == dark[y - 1, x] ? run + 1 : 1;
                if (run == 5) score += 3; else if (run > 5) score++;
            }
        }
        for (var y = 0; y < size - 1; y++)
            for (var x = 0; x < size - 1; x++)
                if (dark[y, x] == dark[y, x + 1] && dark[y, x] == dark[y + 1, x] && dark[y, x] == dark[y + 1, x + 1]) score += 3;
        var count = 0;
        foreach (var d in dark) if (d) count++;
        score += Math.Abs(count * 20 - size * size * 10) / (size * size) * 10;
        return score;
    }

    /// <summary>The modules of the code for a text: [y, x], true = dark.</summary>
    public static bool[,] Encode(string text)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(text);
        var version = 1;
        while (version <= 10 && bytes.Length * 8 + 4 + (version < 10 ? 8 : 16) > DataCodewords(version) * 8) version++;
        if (version > 10) throw new ArgumentException("The text is too long for the QR code");
        var codewords = Interleave(BitsFor(bytes, version), version);
        bool[,]? best = null;
        var bestScore = int.MaxValue;
        for (var mask = 0; mask < 8; mask++)
        {
            var matrix = Build(codewords, version, mask);
            var score = Penalty(matrix);
            if (score < bestScore) { best = matrix; bestScore = score; }
        }
        return best!;
    }
}
