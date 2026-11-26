namespace Muna.Core;

/// <summary>Cuts an H.264 byte stream (Annex B: NAL units after 00 00 01 or 00 00 00 01, as Android's
/// screenrecord writes it) into access units: the parameter sets and the slice of one picture together,
/// what a decoder takes as one sample. Bytes come in any pieces; <see cref="Push"/> returns the units
/// that are complete.</summary>
public sealed class AnnexB
{
    readonly List<byte> _buffer = new();
    readonly List<byte> _unit = new();
    bool _unitHasPicture;

    public List<byte[]> Push(ReadOnlySpan<byte> bytes)
    {
        var done = new List<byte[]>();
        _buffer.AddRange(bytes.ToArray());
        // every NAL that has a start code after it is complete
        while (true)
        {
            var first = StartCode(0, out var firstLength);
            if (first < 0) { if (_buffer.Count > 4 * 1024 * 1024) _buffer.Clear(); break; }
            if (first > 0) _buffer.RemoveRange(0, first);   // bytes before the first start code: not ours
            var next = StartCode(firstLength, out _);
            if (next < 0) break;
            var nal = _buffer.GetRange(0, next).ToArray();
            _buffer.RemoveRange(0, next);
            Add(nal, firstLength, done);
        }
        return done;
    }

    void Add(byte[] nal, int startLength, List<byte[]> done)
    {
        if (nal.Length <= startLength) return;
        var type = nal[startLength] & 0x1F;
        var picture = type is 1 or 5;
        // a new picture begins with parameter sets, an access unit delimiter or SEI after a picture: the unit before is done
        if (_unitHasPicture && (picture || type is 6 or 7 or 8 or 9))
        {
            done.Add(_unit.ToArray());
            _unit.Clear();
            _unitHasPicture = false;
        }
        _unit.AddRange(nal);
        if (picture)
        {
            // one slice per picture (screenrecord): it can go at once
            done.Add(_unit.ToArray());
            _unit.Clear();
            _unitHasPicture = false;
        }
    }

    /// <summary>The index of the next 00 00 01 (or 00 00 00 01) at or after <paramref name="from"/>, or -1.</summary>
    int StartCode(int from, out int length)
    {
        length = 0;
        for (var i = from; i + 2 < _buffer.Count; i++)
        {
            if (_buffer[i] != 0 || _buffer[i + 1] != 0) continue;
            if (_buffer[i + 2] == 1) { length = 3; return i > 0 && _buffer[i - 1] == 0 && i - 1 >= from ? Back(i, ref length) : i; }
        }
        return -1;
    }

    static int Back(int i, ref int length)
    {
        length = 4;
        return i - 1;
    }

    /// <summary>The NAL type of the first NAL of a unit (7 SPS, 8 PPS, 5 IDR picture, 1 picture).</summary>
    public static int FirstType(byte[] unit)
    {
        var offset = unit.Length > 3 && unit[2] == 1 ? 3 : 4;
        return unit.Length > offset ? unit[offset] & 0x1F : -1;
    }
}
