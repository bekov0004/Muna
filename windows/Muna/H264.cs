using System;
using System.Runtime.InteropServices;

namespace Muna;

/// <summary>Windows' own H.264 decoder (the Media Foundation transform every Windows 10 and 11 has),
/// called through its COM table directly: access units in, pictures out as BGRA. One instance per
/// stream, used from one thread.</summary>
public sealed unsafe class H264Decoder : IDisposable
{
    static readonly Guid MediaTypeVideo = new("73646976-0000-0010-8000-00AA00389B71");
    static readonly Guid FormatH264 = new("34363248-0000-0010-8000-00AA00389B71");
    static readonly Guid FormatNV12 = new("3231564E-0000-0010-8000-00AA00389B71");
    static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    static readonly Guid SubType = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    static readonly Guid LowLatency = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    static readonly Guid DecoderClass = new("62CE7E72-4C71-4d20-B15D-452831A87D9D");
    static readonly Guid TransformInterface = new("bf94c121-5b05-4e6f-8000-ba598961414d");

    const int NotAccepting = unchecked((int)0xC00D36B5), NeedMoreInput = unchecked((int)0xC00D6D72), StreamChange = unchecked((int)0xC00D6D61);

    [DllImport("mfplat.dll")] static extern int MFStartup(int version, int flags);
    [DllImport("mfplat.dll")] static extern int MFShutdown();
    [DllImport("mfplat.dll")] static extern int MFCreateMediaType(out IntPtr type);
    [DllImport("mfplat.dll")] static extern int MFCreateSample(out IntPtr sample);
    [DllImport("mfplat.dll")] static extern int MFCreateMemoryBuffer(int length, out IntPtr buffer);
    [DllImport("ole32.dll")] static extern int CoCreateInstance(in Guid clsid, IntPtr outer, int context, in Guid iid, out IntPtr instance);
    [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr reserved, int flags);

    [StructLayout(LayoutKind.Sequential)] struct OutputStreamInfo { public int Flags, Size, Alignment; }
    [StructLayout(LayoutKind.Sequential)] struct OutputDataBuffer { public int StreamId; public IntPtr Sample; public int Status; public IntPtr Events; }

    IntPtr _transform;
    long _time;
    int _width, _height, _stride, _outputSize;
    bool _providesSamples;

    /// <summary>The size of the pictures (the decoder's, before cropping).</summary>
    public int Width => _width;
    public int Height => _height;

    static IntPtr* Table(IntPtr p) => *(IntPtr**)p;
    static void Release(IntPtr p) { if (p != IntPtr.Zero) ((delegate* unmanaged[Stdcall]<IntPtr, uint>)Table(p)[2])(p); }
    static void Check(int hr, string what) { if (hr < 0) throw new COMException($"H.264 decoder: {what} (0x{hr:X8})", hr); }

    // IMFAttributes (also IMFMediaType, IMFSample): GetUINT32 7, GetUINT64 8, SetUINT32 21, SetUINT64 22, SetGUID 24
    static int SetGuid(IntPtr a, Guid key, Guid value) => ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, Guid*, int>)Table(a)[24])(a, &key, &value);
    static int SetUInt32(IntPtr a, Guid key, uint value) => ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, uint, int>)Table(a)[21])(a, &key, value);
    static int GetUInt32(IntPtr a, Guid key, out uint value) { uint v; var hr = ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, uint*, int>)Table(a)[7])(a, &key, &v); value = v; return hr; }
    static int GetUInt64(IntPtr a, Guid key, out ulong value) { ulong v; var hr = ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, ulong*, int>)Table(a)[8])(a, &key, &v); value = v; return hr; }
    static int GetGuid(IntPtr a, Guid key, out Guid value) { Guid v; var hr = ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, Guid*, int>)Table(a)[10])(a, &key, &v); value = v; return hr; }

    public H264Decoder()
    {
        CoInitializeEx(IntPtr.Zero, 0);
        Check(MFStartup(0x00020070, 0), "start");
        Check(CoCreateInstance(DecoderClass, IntPtr.Zero, 1, TransformInterface, out _transform), "create");
        // IMFTransform::GetAttributes (8): low latency, a picture comes out as soon as it is decoded
        IntPtr attributes;
        if (((delegate* unmanaged[Stdcall]<IntPtr, IntPtr*, int>)Table(_transform)[8])(_transform, &attributes) >= 0 && attributes != IntPtr.Zero)
        {
            SetUInt32(attributes, LowLatency, 1);
            Release(attributes);
        }
        Check(MFCreateMediaType(out var input), "input type");
        try
        {
            SetGuid(input, MajorType, MediaTypeVideo);
            SetGuid(input, SubType, FormatH264);
            Check(((delegate* unmanaged[Stdcall]<IntPtr, int, IntPtr, int, int>)Table(_transform)[15])(_transform, 0, input, 0), "set input");   // SetInputType
        }
        finally { Release(input); }
        ChooseOutput();
        ((delegate* unmanaged[Stdcall]<IntPtr, int, nuint, int>)Table(_transform)[23])(_transform, 0x10000000, 0);   // NOTIFY_BEGIN_STREAMING
        ((delegate* unmanaged[Stdcall]<IntPtr, int, nuint, int>)Table(_transform)[23])(_transform, 0x10000003, 0);   // NOTIFY_START_OF_STREAM
    }

    /// <summary>NV12 out (every H.264 decoder offers it); reads the picture size and the buffer it needs.</summary>
    void ChooseOutput()
    {
        for (var i = 0; ; i++)
        {
            IntPtr type;
            var hr = ((delegate* unmanaged[Stdcall]<IntPtr, int, int, IntPtr*, int>)Table(_transform)[14])(_transform, 0, i, &type);   // GetOutputAvailableType
            if (hr < 0) break;
            try
            {
                if (GetGuid(type, SubType, out var subtype) >= 0 && subtype == FormatNV12)
                {
                    Check(((delegate* unmanaged[Stdcall]<IntPtr, int, IntPtr, int, int>)Table(_transform)[16])(_transform, 0, type, 0), "set output");   // SetOutputType
                    if (GetUInt64(type, FrameSize, out var size) >= 0) { _width = (int)(size >> 32); _height = (int)(size & 0xffffffff); }
                    _stride = GetUInt32(type, DefaultStride, out var stride) >= 0 && (int)stride > 0 ? (int)stride : _width;
                    break;
                }
            }
            finally { Release(type); }
        }
        OutputStreamInfo info;
        ((delegate* unmanaged[Stdcall]<IntPtr, int, OutputStreamInfo*, int>)Table(_transform)[7])(_transform, 0, &info);   // GetOutputStreamInfo
        _providesSamples = (info.Flags & 0x100) != 0 || (info.Flags & 0x200) != 0;
        _outputSize = Math.Max(info.Size, _stride * Math.Max(_height, 16) * 3 / 2);
    }

    /// <summary>Gives the decoder one access unit; calls <paramref name="picture"/> for every picture
    /// that comes out (BGRA, cropped to <paramref name="width"/> × <paramref name="height"/>).</summary>
    public void Decode(byte[] unit, int width, int height, Action<byte[], int, int> picture)
    {
        Check(MFCreateMemoryBuffer(unit.Length, out var buffer), "buffer");
        Check(MFCreateSample(out var sample), "sample");
        try
        {
            byte* data;
            int max, current;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, byte**, int*, int*, int>)Table(buffer)[3])(buffer, &data, &max, &current), "lock");
            Marshal.Copy(unit, 0, (IntPtr)data, unit.Length);
            ((delegate* unmanaged[Stdcall]<IntPtr, int>)Table(buffer)[4])(buffer);                                // Unlock
            ((delegate* unmanaged[Stdcall]<IntPtr, int, int>)Table(buffer)[6])(buffer, unit.Length);              // SetCurrentLength
            ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)Table(sample)[42])(sample, buffer);              // AddBuffer
            ((delegate* unmanaged[Stdcall]<IntPtr, long, int>)Table(sample)[36])(sample, _time);                  // SetSampleTime
            _time += 333_333;
            var hr = ProcessInput(sample);
            if (hr == NotAccepting)
            {
                Drain(width, height, picture);
                hr = ProcessInput(sample);
            }
            Check(hr, "input");
            Drain(width, height, picture);
        }
        finally
        {
            Release(sample);
            Release(buffer);
        }
    }

    int ProcessInput(IntPtr sample) => ((delegate* unmanaged[Stdcall]<IntPtr, int, IntPtr, int, int>)Table(_transform)[24])(_transform, 0, sample, 0);

    void Drain(int width, int height, Action<byte[], int, int> picture)
    {
        for (var guard = 0; guard < 8; guard++)
        {
            IntPtr sample = IntPtr.Zero, buffer = IntPtr.Zero;
            if (!_providesSamples)
            {
                Check(MFCreateSample(out sample), "out sample");
                Check(MFCreateMemoryBuffer(_outputSize, out buffer), "out buffer");
                ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)Table(sample)[42])(sample, buffer);
            }
            var output = new OutputDataBuffer { StreamId = 0, Sample = sample };
            int status;
            var hr = ((delegate* unmanaged[Stdcall]<IntPtr, int, int, OutputDataBuffer*, int*, int>)Table(_transform)[25])(_transform, 0, 1, &output, &status);   // ProcessOutput
            try
            {
                if (output.Events != IntPtr.Zero) Release(output.Events);
                if (hr == NeedMoreInput) return;
                if (hr == StreamChange) { ChooseOutput(); continue; }
                Check(hr, "output");
                if (output.Sample != IntPtr.Zero) Convert(output.Sample, width, height, picture);
            }
            finally
            {
                if (_providesSamples && output.Sample != IntPtr.Zero) Release(output.Sample);
                Release(buffer);
                Release(sample);
            }
        }
    }

    void Convert(IntPtr sample, int width, int height, Action<byte[], int, int> picture)
    {
        IntPtr buffer;
        Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr*, int>)Table(sample)[41])(sample, &buffer), "contiguous");   // ConvertToContiguousBuffer
        try
        {
            byte* data;
            int max, length;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, byte**, int*, int*, int>)Table(buffer)[3])(buffer, &data, &max, &length), "lock out");
            try
            {
                int w = Math.Min(width, _width), h = Math.Min(height, _height), stride = _stride;
                // the chroma plane starts after the luma plane of the (aligned) picture
                var planeHeight = length >= stride * _height * 3 / 2 ? _height : h;
                if (length < stride * planeHeight + stride * (planeHeight / 2)) return;
                var bgra = new byte[w * h * 4];
                var uvBase = data + stride * planeHeight;
                for (var y = 0; y < h; y++)
                {
                    var row = data + y * stride;
                    var uvRow = uvBase + (y / 2) * stride;
                    var o = y * w * 4;
                    for (var x = 0; x < w; x++)
                    {
                        var c = row[x] - 16;
                        var d = uvRow[x & ~1] - 128;
                        var e = uvRow[(x & ~1) + 1] - 128;
                        var r = (298 * c + 409 * e + 128) >> 8;
                        var g = (298 * c - 100 * d - 208 * e + 128) >> 8;
                        var b = (298 * c + 516 * d + 128) >> 8;
                        bgra[o++] = (byte)Math.Clamp(b, 0, 255);
                        bgra[o++] = (byte)Math.Clamp(g, 0, 255);
                        bgra[o++] = (byte)Math.Clamp(r, 0, 255);
                        bgra[o++] = 255;
                    }
                }
                picture(bgra, w, h);
            }
            finally { ((delegate* unmanaged[Stdcall]<IntPtr, int>)Table(buffer)[4])(buffer); }
        }
        finally { Release(buffer); }
    }

    public void Dispose()
    {
        if (_transform == IntPtr.Zero) return;
        Release(_transform);
        _transform = IntPtr.Zero;
        MFShutdown();
    }
}
