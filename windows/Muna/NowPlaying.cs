using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Muna.Core;
using Windows.Media.Control;

namespace Muna;

public sealed record Track(string Title, string Artist, string Album, double Duration, ImageSource? Artwork, string App);

/// <summary>What plays now, from any app that tells Windows (the media overlay's source:
/// Spotify, browsers, the Media Player …); play, pause, next, previous, jump.</summary>
public sealed class NowPlaying : Model
{
    GlobalSystemMediaTransportControlsSessionManager? _manager;
    GlobalSystemMediaTransportControlsSession? _session;
    readonly LyricsClient _lyrics = new();
    string _lyricsKey = "";
    double _position;
    DateTime _positionAt = DateTime.Now;

    public Track? Track { get; private set; }
    public bool IsPlaying { get; private set; }
    public LyricsResult? Lyrics { get; private set; }
    public event Action<bool>? PlayingChanged;

    public async void Start()
    {
        try
        {
            _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            _manager.CurrentSessionChanged += (_, _) => Ui(Attach);
            _manager.SessionsChanged += (_, _) => Ui(Attach);
            Attach();
            Preferences.Shared.Changed += key => { if (key == "show-lyrics") _ = LoadLyrics(); };
        }
        catch
        {
            // no media service (Windows N without the media pack)
        }
    }

    void Attach()
    {
        var session = _manager?.GetCurrentSession();
        if (session != _session)
        {
            if (_session is not null)
            {
                _session.MediaPropertiesChanged -= OnProperties;
                _session.PlaybackInfoChanged -= OnPlayback;
                _session.TimelinePropertiesChanged -= OnTimeline;
            }
            _session = session;
            if (session is not null)
            {
                session.MediaPropertiesChanged += OnProperties;
                session.PlaybackInfoChanged += OnPlayback;
                session.TimelinePropertiesChanged += OnTimeline;
            }
        }
        Refresh();
    }

    void OnProperties(GlobalSystemMediaTransportControlsSession s, MediaPropertiesChangedEventArgs e) => Ui(Refresh);
    void OnPlayback(GlobalSystemMediaTransportControlsSession s, PlaybackInfoChangedEventArgs e) => Ui(ReadPlayback);
    void OnTimeline(GlobalSystemMediaTransportControlsSession s, TimelinePropertiesChangedEventArgs e) => Ui(ReadTimeline);

    /// <summary>Asks again (the panel opened).</summary>
    public async void Refresh()
    {
        var session = _session;
        if (session is null)
        {
            SetTrack(null);
            return;
        }
        try
        {
            var properties = await session.TryGetMediaPropertiesAsync();
            if (session != _session) return;
            if (properties is null || string.IsNullOrWhiteSpace(properties.Title))
            {
                SetTrack(null);
                return;
            }
            ImageSource? artwork = null;
            if (properties.Thumbnail is not null)
            {
                try
                {
                    using var stream = await properties.Thumbnail.OpenReadAsync();
                    using var input = stream.AsStreamForRead();
                    var memory = new MemoryStream();
                    await input.CopyToAsync(memory);
                    memory.Position = 0;
                    var image = new BitmapImage();
                    image.BeginInit();
                    image.CacheOption = BitmapCacheOption.OnLoad;
                    image.DecodePixelWidth = 128;
                    image.StreamSource = memory;
                    image.EndInit();
                    image.Freeze();
                    artwork = image;
                }
                catch { /* no picture */ }
            }
            var timeline = session.GetTimelineProperties();
            var duration = (timeline.EndTime - timeline.StartTime).TotalSeconds;
            var app = session.SourceAppUserModelId ?? "";
            SetTrack(new Track(properties.Title, properties.Artist ?? "", properties.AlbumTitle ?? "", duration > 0 ? duration : 0, artwork,
                               app.Split('!')[0].Replace(".exe", "", StringComparison.OrdinalIgnoreCase)));
            ReadPlayback();
            ReadTimeline();
        }
        catch
        {
            SetTrack(null);
        }
    }

    void SetTrack(Track? track)
    {
        var changed = track?.Title != Track?.Title || track?.Artist != Track?.Artist;
        Track = track;
        if (track is null && IsPlaying)
        {
            IsPlaying = false;
            PlayingChanged?.Invoke(false);
        }
        if (changed) _ = LoadLyrics();
        Notify();
    }

    void ReadPlayback()
    {
        var playing = _session?.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        if (playing == IsPlaying) return;
        _position = CurrentPosition();
        _positionAt = DateTime.Now;
        IsPlaying = playing;
        PlayingChanged?.Invoke(playing);
        Notify();
    }

    void ReadTimeline()
    {
        var timeline = _session?.GetTimelineProperties();
        if (timeline is null) return;
        _position = (timeline.Position - timeline.StartTime).TotalSeconds;
        _positionAt = timeline.LastUpdatedTime.LocalDateTime;
        if (_positionAt > DateTime.Now || _positionAt.Year < 2000) _positionAt = DateTime.Now;
        var duration = (timeline.EndTime - timeline.StartTime).TotalSeconds;
        if (Track is { } track && duration > 0 && Math.Abs(track.Duration - duration) > 1) Track = track with { Duration = duration };
        Notify();
    }

    /// <summary>Where the song is now (counted on from the last report while it plays).</summary>
    public double CurrentPosition()
    {
        var position = _position + (IsPlaying ? (DateTime.Now - _positionAt).TotalSeconds : 0);
        var duration = Track?.Duration ?? 0;
        return Math.Max(0, duration > 0 ? Math.Min(position, duration) : position);
    }

    async Task LoadLyrics()
    {
        var track = Track;
        Lyrics = null;
        if (track is null || !Preferences.Shared.ShowLyrics) { Notify(); return; }
        var key = $"{track.Artist}\n{track.Title}";
        _lyricsKey = key;
        var result = await _lyrics.Lookup(track.Artist, track.Title, track.Album, track.Duration);
        if (_lyricsKey != key) return;
        Lyrics = result;
        Notify();
    }

    public string? LyricLine()
    {
        if (!Preferences.Shared.ShowLyrics) return null;
        var line = Lyrics?.LineAt(CurrentPosition());
        return string.IsNullOrWhiteSpace(line?.Text) ? null : line!.Text;
    }

    public async void PlayPause()
    {
        if (_session is null) { Native.TapKey(Native.VK_MEDIA_PLAY_PAUSE); return; }
        try { await _session.TryTogglePlayPauseAsync(); } catch { Native.TapKey(Native.VK_MEDIA_PLAY_PAUSE); }
    }

    public async void Next()
    {
        if (_session is null) { Native.TapKey(Native.VK_MEDIA_NEXT); return; }
        try { await _session.TrySkipNextAsync(); } catch { Native.TapKey(Native.VK_MEDIA_NEXT); }
    }

    public async void Previous()
    {
        if (_session is null) { Native.TapKey(Native.VK_MEDIA_PREV); return; }
        try { await _session.TrySkipPreviousAsync(); } catch { Native.TapKey(Native.VK_MEDIA_PREV); }
    }

    public async void Seek(double seconds)
    {
        if (_session is null) return;
        try
        {
            if (await _session.TryChangePlaybackPositionAsync(TimeSpan.FromSeconds(seconds).Ticks))
            {
                _position = seconds;
                _positionAt = DateTime.Now;
                Notify();
            }
        }
        catch { /* the app does not jump */ }
    }
}
