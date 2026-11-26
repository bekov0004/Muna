using System;
using System.Windows.Threading;
using Windows.Security.Credentials.UI;

namespace Muna;

/// <summary>Private notes and clipboard items open with Windows Hello (face, fingerprint or the PIN)
/// for 5 minutes, as Linux does with the fingerprint and the Mac with Touch ID.</summary>
public sealed class PrivacyModel : Model
{
    public bool Unlocked { get; private set; }
    public string? Problem { get; private set; }
    readonly DispatcherTimer _lock = new() { Interval = TimeSpan.FromMinutes(5) };
    bool _asking;

    public PrivacyModel() => _lock.Tick += (_, _) => Lock();

    public async void Unlock()
    {
        if (Unlocked || _asking) return;
        _asking = true;
        try
        {
            var available = await UserConsentVerifier.CheckAvailabilityAsync();
            if (available != UserConsentVerifierAvailability.Available)
            {
                Problem = "Set up Windows Hello (a PIN is enough) in Settings → Accounts → Sign-in options";
                Notify();
                return;
            }
            var result = await UserConsentVerifier.RequestVerificationAsync("Muna: show the private items");
            if (result == UserConsentVerificationResult.Verified)
            {
                Unlocked = true;
                Problem = null;
                _lock.Stop();
                _lock.Start();
                Notify();
            }
        }
        catch
        {
            Problem = "Windows Hello did not answer";
            Notify();
        }
        finally
        {
            _asking = false;
        }
    }

    public void Lock()
    {
        _lock.Stop();
        if (!Unlocked) return;
        Unlocked = false;
        Notify();
    }
}
