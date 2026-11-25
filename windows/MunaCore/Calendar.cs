using System.Globalization;
using System.Text;

namespace Muna.Core;

public sealed record Recurrence(string Frequency, int Interval, int? Count, DateTime? Until, List<DayOfWeek> ByDay);

/// <summary>One event of a calendar (times in local time); a repeating one carries its rule.</summary>
public sealed record CalendarEvent(string Uid, string Title, DateTime Start, DateTime End, bool AllDay,
                                   Recurrence? Rule = null, HashSet<DateTime>? Skipped = null);

/// <summary>Reads iCalendar (.ics) files, the "secret address" Outlook and Google give a calendar.
/// Enough of RFC 5545 for a widget: events, all-day ones, time zones, the common repeat rules,
/// skipped and moved occurrences.</summary>
public static class IcsCalendar
{
    public static List<CalendarEvent> Parse(string text)
    {
        var lines = Unfold(text);
        var events = new List<CalendarEvent>();
        var moved = new List<(string Uid, DateTime Original)>();
        Dictionary<string, (string Params, string Value)>? current = null;
        var exdates = new List<(string Params, string Value)>();
        foreach (var line in lines)
        {
            if (line == "BEGIN:VEVENT") { current = new(StringComparer.OrdinalIgnoreCase); exdates = new(); continue; }
            if (line == "END:VEVENT")
            {
                if (current is not null && Make(current, exdates) is { } made)
                {
                    events.Add(made);
                    if (current.TryGetValue("RECURRENCE-ID", out var rid) && Time(rid.Params, rid.Value) is { } original)
                        moved.Add((made.Uid, original.Time));
                }
                current = null;
                continue;
            }
            if (current is null) continue;
            var colon = FindColon(line);
            if (colon < 0) continue;
            var head = line[..colon];
            var value = line[(colon + 1)..];
            var semi = head.IndexOf(';');
            var name = semi < 0 ? head : head[..semi];
            var parameters = semi < 0 ? "" : head[(semi + 1)..];
            if (name.Equals("EXDATE", StringComparison.OrdinalIgnoreCase)) exdates.Add((parameters, value));
            else current.TryAdd(name, (parameters, value));
        }
        // an occurrence moved elsewhere is skipped by its series
        var result = new List<CalendarEvent>();
        foreach (var e in events)
        {
            if (e.Rule is not null)
            {
                foreach (var m in moved.Where(m => m.Uid == e.Uid)) e.Skipped!.Add(m.Original);
            }
            result.Add(e);
        }
        return result;
    }

    static int FindColon(string line)
    {
        var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            if (line[i] == '"') quoted = !quoted;
            else if (line[i] == ':' && !quoted) return i;
        }
        return -1;
    }

    static List<string> Unfold(string text)
    {
        var lines = new List<string>();
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            if ((raw.StartsWith(' ') || raw.StartsWith('\t')) && lines.Count > 0) lines[^1] += raw[1..];
            else if (raw.Length > 0) lines.Add(raw);
        }
        return lines;
    }

    static CalendarEvent? Make(Dictionary<string, (string Params, string Value)> p, List<(string Params, string Value)> exdates)
    {
        if (p.TryGetValue("STATUS", out var status) && status.Value.Equals("CANCELLED", StringComparison.OrdinalIgnoreCase)) return null;
        if (!p.TryGetValue("DTSTART", out var start) || Time(start.Params, start.Value) is not { } s) return null;
        DateTime end;
        if (p.TryGetValue("DTEND", out var endValue) && Time(endValue.Params, endValue.Value) is { } e) end = e.Time;
        else if (p.TryGetValue("DURATION", out var duration) && ParseDuration(duration.Value) is { } d) end = s.Time + d;
        else end = s.AllDay ? s.Time.AddDays(1) : s.Time;
        if (end < s.Time) end = s.Time;
        var title = p.TryGetValue("SUMMARY", out var summary) ? Unescape(summary.Value) : "Event";
        var uid = p.TryGetValue("UID", out var u) ? u.Value : Guid.NewGuid().ToString();
        Recurrence? rule = null;
        HashSet<DateTime>? skipped = null;
        if (!p.ContainsKey("RECURRENCE-ID") && p.TryGetValue("RRULE", out var rrule))
        {
            rule = ParseRule(rrule.Value, s.AllDay);
            skipped = new HashSet<DateTime>();
            foreach (var (parameters, value) in exdates)
                foreach (var one in value.Split(','))
                    if (Time(parameters, one) is { } x) skipped.Add(x.Time);
        }
        return new CalendarEvent(uid, title.Length == 0 ? "Event" : title, s.Time, end, s.AllDay, rule, skipped);
    }

    static string Unescape(string value)
    {
        var builder = new StringBuilder();
        for (var i = 0; i < value.Length; i++)
        {
            if (value[i] == '\\' && i + 1 < value.Length)
            {
                var next = value[++i];
                builder.Append(next is 'n' or 'N' ? ' ' : next);
            }
            else builder.Append(value[i]);
        }
        return builder.ToString().Trim();
    }

    /// <summary>A DATE or DATE-TIME value in local time.</summary>
    static (DateTime Time, bool AllDay)? Time(string parameters, string value)
    {
        value = value.Trim();
        if (parameters.Contains("VALUE=DATE", StringComparison.OrdinalIgnoreCase) && !parameters.Contains("VALUE=DATE-TIME", StringComparison.OrdinalIgnoreCase) || value.Length == 8)
        {
            return DateTime.TryParseExact(value[..Math.Min(8, value.Length)], "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day)
                ? (day, true) : null;
        }
        var utc = value.EndsWith('Z');
        if (!DateTime.TryParseExact(value.TrimEnd('Z'), new[] { "yyyyMMdd'T'HHmmss", "yyyyMMdd'T'HHmm" }, CultureInfo.InvariantCulture, DateTimeStyles.None, out var time))
            return null;
        if (utc) return (DateTime.SpecifyKind(time, DateTimeKind.Utc).ToLocalTime(), false);
        var tzid = parameters.Split(';').Select(x => x.Split('=', 2)).FirstOrDefault(x => x.Length == 2 && x[0].Equals("TZID", StringComparison.OrdinalIgnoreCase))?[1].Trim('"');
        if (tzid is not null && Zone(tzid) is { } zone)
        {
            try { return (TimeZoneInfo.ConvertTime(DateTime.SpecifyKind(time, DateTimeKind.Unspecified), zone, TimeZoneInfo.Local), false); }
            catch { /* a time that does not exist there */ }
        }
        return (time, false);
    }

    static readonly Dictionary<string, TimeZoneInfo?> Zones = new();

    static TimeZoneInfo? Zone(string id)
    {
        lock (Zones)
        {
            if (Zones.TryGetValue(id, out var known)) return known;
            TimeZoneInfo? zone = null;
            // Outlook writes Windows names, Google IANA ones; some add a prefix ("/mozilla.org/…/Europe/Berlin")
            foreach (var candidate in new[] { id, id.Contains('/') ? string.Join("/", id.Split('/').TakeLast(2)) : id })
            {
                try { zone = TimeZoneInfo.FindSystemTimeZoneById(candidate); break; }
                catch { /* the next */ }
            }
            Zones[id] = zone;
            return zone;
        }
    }

    static TimeSpan? ParseDuration(string value)
    {
        var match = System.Text.RegularExpressions.Regex.Match(value.Trim(), @"^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$");
        if (!match.Success) return null;
        int N(int g) => match.Groups[g].Success ? int.Parse(match.Groups[g].Value, CultureInfo.InvariantCulture) : 0;
        var span = new TimeSpan(N(2) * 7 + N(3), N(4), N(5), N(6));
        return match.Groups[1].Value == "-" ? -span : span;
    }

    static readonly Dictionary<string, DayOfWeek> Days = new()
    {
        ["MO"] = DayOfWeek.Monday, ["TU"] = DayOfWeek.Tuesday, ["WE"] = DayOfWeek.Wednesday, ["TH"] = DayOfWeek.Thursday,
        ["FR"] = DayOfWeek.Friday, ["SA"] = DayOfWeek.Saturday, ["SU"] = DayOfWeek.Sunday,
    };

    static Recurrence? ParseRule(string value, bool allDay)
    {
        var parts = value.Split(';').Select(x => x.Split('=', 2)).Where(x => x.Length == 2).ToDictionary(x => x[0].ToUpperInvariant(), x => x[1]);
        if (!parts.TryGetValue("FREQ", out var frequency) || frequency is not ("DAILY" or "WEEKLY" or "MONTHLY" or "YEARLY")) return null;
        var interval = parts.TryGetValue("INTERVAL", out var i) && int.TryParse(i, out var n) && n > 0 ? n : 1;
        int? count = parts.TryGetValue("COUNT", out var c) && int.TryParse(c, out var cn) ? cn : null;
        DateTime? until = parts.TryGetValue("UNTIL", out var u) ? Time(u.Length == 8 ? "VALUE=DATE" : "", u)?.Time : null;
        if (until is { } day && (allDay || u!.Length == 8)) until = day.Date.AddDays(1).AddTicks(-1);
        var byDay = parts.TryGetValue("BYDAY", out var b)
            ? b.Split(',').Select(x => x.Length >= 2 ? x[^2..] : x).Where(Days.ContainsKey).Select(x => Days[x]).ToList()
            : new List<DayOfWeek>();
        return new Recurrence(frequency, interval, count, until, byDay);
    }

    /// <summary>The events (repeating ones as their occurrences) that touch [from, to).</summary>
    public static List<CalendarEvent> Occurrences(IEnumerable<CalendarEvent> events, DateTime from, DateTime to)
    {
        var result = new List<CalendarEvent>();
        foreach (var e in events)
        {
            var length = e.End - e.Start;
            if (e.Rule is null)
            {
                if (Touches(e.Start, e.End, e.AllDay, from, to)) result.Add(e);
                continue;
            }
            foreach (var start in Starts(e, to))
            {
                if (e.Skipped?.Contains(start) == true) continue;
                if (Touches(start, start + length, e.AllDay, from, to)) result.Add(e with { Start = start, End = start + length, Rule = null });
            }
        }
        return result;
    }

    static bool Touches(DateTime start, DateTime end, bool allDay, DateTime from, DateTime to) =>
        end > start ? start < to && end > from : start >= from && start < to;

    /// <summary>The starts of a repeating event, in order, until `to` (or its own end).</summary>
    static IEnumerable<DateTime> Starts(CalendarEvent e, DateTime to)
    {
        var rule = e.Rule!;
        var produced = 0;
        for (var step = 0; step < 20000; step++)
        {
            IEnumerable<DateTime> candidates;
            switch (rule.Frequency)
            {
                case "DAILY":
                    candidates = new[] { e.Start.AddDays(step * rule.Interval) };
                    break;
                case "WEEKLY":
                    var weekStart = e.Start.AddDays(step * 7 * rule.Interval);
                    var monday = weekStart.AddDays(-(((int)weekStart.DayOfWeek + 6) % 7));
                    candidates = rule.ByDay.Count == 0
                        ? new[] { weekStart }
                        : rule.ByDay.Select(d => monday.AddDays(((int)d + 6) % 7)).OrderBy(x => x).Where(x => x >= e.Start);
                    break;
                case "MONTHLY":
                    var month = e.Start.AddMonths(step * rule.Interval);
                    candidates = month.Day == e.Start.Day ? new[] { month } : Array.Empty<DateTime>();
                    break;
                default:
                    var year = e.Start.AddYears(step * rule.Interval);
                    candidates = year.Day == e.Start.Day ? new[] { year } : Array.Empty<DateTime>();
                    break;
            }
            foreach (var start in candidates)
            {
                if (start >= to || (rule.Until is { } until && start > until)) yield break;
                if (rule.Count is { } count && produced >= count) yield break;
                produced++;
                yield return start;
            }
        }
    }
}
