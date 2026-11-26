using System;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;

namespace Muna;

/// <summary>The camera of the Mirror widget: runs only while the panel shows it (Windows' camera,
/// frames copied into a picture ~15 times a second).</summary>
public sealed class CameraModel : Model
{
    public enum State { Off, Starting, Running, Denied, None }

    public State Access { get; private set; } = State.Off;
    public WriteableBitmap? Frame { get; private set; }
    MediaCapture? _capture;
    MediaFrameReader? _reader;
    int _wanted;
    bool _clicked, _busy;
    DateTime _lastFrame;

    /// <summary>A view showing the camera appeared (true) or went (false).</summary>
    public void Want(bool on)
    {
        _wanted = Math.Max(0, _wanted + (on ? 1 : -1));
        if (_wanted > 0 && (_clicked || Access == State.Running)) _ = Open();
        if (_wanted > 0) return;
        // a page drawn again shows the camera in a new view: stop only if none comes back soon
        var later = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
        later.Tick += (_, _) => { later.Stop(); if (_wanted == 0) Stop(); };
        later.Start();
    }

    /// <summary>The first click on the Mirror (the camera light does not come on by itself).</summary>
    public void Start()
    {
        _clicked = true;
        _ = Open();
    }

    async Task Open()
    {
        if (_capture is not null || _busy) return;
        _busy = true;
        Access = State.Starting;
        Notify();
        try
        {
            var groups = await MediaFrameSourceGroup.FindAllAsync();
            var group = groups.FirstOrDefault(g => g.SourceInfos.Any(s => s.SourceKind == MediaFrameSourceKind.Color && s.MediaStreamType is MediaStreamType.VideoPreview or MediaStreamType.VideoRecord));
            if (group is null)
            {
                Access = State.None;
                return;
            }
            var capture = new MediaCapture();
            await capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                SourceGroup = group, SharingMode = MediaCaptureSharingMode.SharedReadOnly,
                StreamingCaptureMode = StreamingCaptureMode.Video, MemoryPreference = MediaCaptureMemoryPreference.Cpu,
            });
            var source = capture.FrameSources.Values.First(s => s.Info.SourceKind == MediaFrameSourceKind.Color);
            var reader = await capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
            reader.FrameArrived += OnFrame;
            await reader.StartAsync();
            if (_wanted == 0)
            {
                await reader.StopAsync();
                reader.Dispose();
                capture.Dispose();
                Access = State.Off;
                return;
            }
            _capture = capture;
            _reader = reader;
            Access = State.Running;
        }
        catch (UnauthorizedAccessException)
        {
            Access = State.Denied;
        }
        catch
        {
            Access = State.None;
        }
        finally
        {
            _busy = false;
            Notify();
        }
    }

    void OnFrame(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        if ((DateTime.Now - _lastFrame).TotalMilliseconds < 60) return;
        _lastFrame = DateTime.Now;
        using var frame = sender.TryAcquireLatestFrame();
        var bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
        if (bitmap is null) return;
        using var converted = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        int width = converted.PixelWidth, height = converted.PixelHeight;
        var buffer = new Windows.Storage.Streams.Buffer((uint)(width * height * 4));
        converted.CopyToBuffer(buffer);
        var pixels = buffer.ToArray();
        Ui(() =>
        {
            if (Frame is null || Frame.PixelWidth != width || Frame.PixelHeight != height)
            {
                Frame = new WriteableBitmap(width, height, 96, 96, PixelFormats.Pbgra32, null);
                Notify();
            }
            Frame.WritePixels(new Int32Rect(0, 0, width, height), pixels, width * 4, 0);
        });
    }

    public async void Stop()
    {
        var reader = _reader;
        var capture = _capture;
        _reader = null;
        _capture = null;
        if (Access == State.Running) Access = State.Off;
        _clicked = Access == State.Off && _clicked;
        if (reader is not null)
        {
            reader.FrameArrived -= OnFrame;
            try { await reader.StopAsync(); } catch { /* gone */ }
            reader.Dispose();
        }
        capture?.Dispose();
    }
}
