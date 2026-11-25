import SwiftUI

/// The first page: the time, the music, the next events and the open to-dos.
struct HomePage: View {
    @EnvironmentObject var todo: TodoModel
    @EnvironmentObject var model: CapsuleModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.everyMinute) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(context.date, style: .time)
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                        Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(MunaColor.secondary)
                    }
                }
                MusicCard()
                Button {
                    model.tab = .notes
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                        Text(todo.openCount == 0 ? "Nothing to do" : "\(todo.openCount) to do")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(MunaColor.secondary)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 380)
            CalendarCard()
        }
    }
}

struct MusicCard: View {
    @EnvironmentObject var nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 14) {
            if let track = nowPlaying.track {
                Artwork(url: track.artworkURL, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.system(size: 12)).foregroundColor(MunaColor.secondary).lineLimit(1)
                    if track.duration > 0 {
                        ProgressView(value: min(nowPlaying.position, track.duration), total: track.duration)
                            .progressViewStyle(.linear)
                            .tint(MunaColor.accent)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 14) {
                    ControlButton(symbol: "backward.fill") { nowPlaying.previous() }
                    ControlButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 22) { nowPlaying.playPause() }
                    ControlButton(symbol: "forward.fill") { nowPlaying.next() }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 12).fill(MunaColor.tile))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing is playing").font(.system(size: 14, weight: .semibold))
                    Text("Music and Spotify show up here").font(.system(size: 12)).foregroundColor(MunaColor.secondary)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(MunaColor.tile))
    }
}

/// Today's and tomorrow's events.
struct CalendarCard: View {
    @EnvironmentObject var calendar: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Calendar")
            switch calendar.access {
            case .granted:
                if calendar.events.isEmpty {
                    Text("Nothing today or tomorrow").font(.system(size: 12)).foregroundColor(MunaColor.secondary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(calendar.events) { event in
                                EventRow(event: event)
                            }
                        }
                    }
                }
            case .unknown:
                Text("See your next events here").font(.system(size: 12)).foregroundColor(MunaColor.secondary)
                Pill(label: "Show my calendar", accent: true) { calendar.requestAccess() }
            case .denied:
                Text("Muna may not read the calendars: System Settings → Privacy & Security → Calendars")
                    .font(.system(size: 11))
                    .foregroundColor(MunaColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(MunaColor.tile))
    }
}

struct EventRow: View {
    let event: CalendarModel.Event

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(event.color.map { Color(nsColor: $0) } ?? MunaColor.accent)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(when).font(.system(size: 11)).foregroundColor(MunaColor.secondary)
            }
        }
    }

    private var when: String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(event.start) || event.start < Date() ? "Today" :
            calendar.isDateInTomorrow(event.start) ? "Tomorrow" : event.start.formatted(.dateTime.weekday(.wide))
        if event.allDay { return "\(day) · all day" }
        let time = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(time) – \(end)"
    }
}
