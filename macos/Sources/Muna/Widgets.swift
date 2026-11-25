import AVFoundation
import AppKit
import MunaCore
import SwiftUI

// The widgets of the Muna section, drawn after Muna on Linux (linux/src/widgets, linux/stylesheet.css).
// Each one gets its width from the layout and the row's height (112).

// --- Media player -----------------------------------------------------------------------------

struct MediaWidget: View {
    @EnvironmentObject var nowPlaying: NowPlaying

    var body: some View {
        if let track = nowPlaying.track {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Artwork(url: track.artworkURL, size: 64, radius: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.system(size: 13, weight: .bold)).foregroundColor(.white).lineLimit(1)
                        Text(track.album).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6)).lineLimit(1)
                        Text(track.artist).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45)).lineLimit(1)
                        HStack(spacing: 2) {
                            MediaButton(symbol: "backward.fill") { nowPlaying.previous() }
                            MediaButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 16) { nowPlaying.playPause() }
                            MediaButton(symbol: "forward.fill") { nowPlaying.next() }
                            Spacer(minLength: 4)
                            Bars(playing: nowPlaying.isPlaying, color: MunaColor.muna)
                                .frame(width: 24, height: 14)
                                .padding(.trailing, 4)
                        }
                        .padding(.top, 2)
                    }
                }
                if track.duration > 0 {
                    MediaProgress(duration: track.duration)
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 26)).foregroundColor(Color.white.opacity(0.28))
                Text("Nothing is playing").font(.system(size: 11, weight: .semibold)).foregroundColor(Color.white.opacity(0.4))
                Text("Music and Spotify show here").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MediaButton: View {
    let symbol: String
    var size: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.85))
                .frame(width: 26, height: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The time played, a thin bar (a click jumps there), the length.
struct MediaProgress: View {
    let duration: Double
    @EnvironmentObject var nowPlaying: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let position = nowPlaying.currentPosition(at: context.date)
            HStack(spacing: 8) {
                Text(Self.clock(position)).font(.system(size: 9).monospacedDigit()).foregroundColor(Color.white.opacity(0.45))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14)).frame(height: 3)
                        Capsule().fill(Color.white).frame(width: proxy.size.width * CGFloat(position / duration), height: 3)
                    }
                    .frame(height: proxy.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { drag in
                        let share = min(max(0, drag.location.x / max(proxy.size.width, 1)), 1)
                        nowPlaying.seek(to: Double(share) * duration)
                    })
                }
                .frame(height: 10)
                Text(Self.clock(duration)).font(.system(size: 9).monospacedDigit()).foregroundColor(Color.white.opacity(0.45))
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// --- Calendar ---------------------------------------------------------------------------------------

/// The month, a strip of seven days around the chosen one (today in blue), and that day's events.
struct CalendarWidget: View {
    @EnvironmentObject var calendar: CalendarModel
    @EnvironmentObject var ui: PanelState

    private var cal: Calendar { Calendar.current }

    var body: some View {
        let _ = calendar.revision   // ask again when the calendars changed
        let selected = ui.calendarDay
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(selected.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
                Spacer(minLength: 4)
                NavButton(symbol: "chevron.left") { move(-7) }
                NavButton(symbol: "chevron.right") { move(7) }
            }
            HStack(spacing: 0) {
                ForEach(-3...3, id: \.self) { offset in
                    if let day = cal.date(byAdding: .day, value: offset, to: selected) {
                        DayCell(day: day, selected: offset == 0, hasEvents: calendar.hasEvents(on: day)) {
                            ui.calendarDay = day
                        }
                    }
                }
            }
            events(on: selected)
        }
    }

    private func move(_ days: Int) {
        if let day = cal.date(byAdding: .day, value: days, to: ui.calendarDay) {
            ui.calendarDay = day
        }
    }

    @ViewBuilder private func events(on day: Date) -> some View {
        switch calendar.access {
        case .granted:
            let events = calendar.events(on: day)
            if events.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 11))
                    Text(cal.isDateInToday(day) ? "Nothing for today" : "Nothing this day").font(.system(size: 11))
                }
                .foregroundColor(Color.white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events.prefix(2)) { event in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(event.color.map { Color(nsColor: $0) } ?? MunaColor.accent)
                                .frame(width: 3, height: 12)
                            Text(event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundColor(Color.white.opacity(0.5))
                            Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        }
                    }
                    if events.count > 2 {
                        Text("+\(events.count - 2) more").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4))
                    }
                }
            }
        case .unknown:
            Pill(label: "Show my calendar", accent: true) { calendar.requestAccess() }
                .frame(maxWidth: .infinity)
        case .denied:
            Text("Allow Calendars for Muna in System Settings → Privacy")
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.4))
                .lineLimit(2)
        }
    }
}

struct NavButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color.white.opacity(0.45))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct DayCell: View {
    let day: Date
    let selected: Bool
    let hasEvents: Bool
    let action: () -> Void

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.isDateInToday(day)
        let weekend = calendar.isDateInWeekend(day)
        Button(action: action) {
            VStack(spacing: 1) {
                Text(String(day.formatted(.dateTime.weekday(.narrow))))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.32))
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: today ? .heavy : .semibold).monospacedDigit())
                    .foregroundColor(today ? MunaColor.accent : weekend ? Color(red: 1, green: 0.45, blue: 0.45).opacity(0.85) : Color.white.opacity(0.78))
                Circle()
                    .fill(hasEvents ? Color.white.opacity(0.5) : Color.clear)
                    .frame(width: 3, height: 3)
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.10 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// --- Mirror -----------------------------------------------------------------------------------

/// A round camera preview, running only while it is seen.
struct MirrorWidget: View {
    @EnvironmentObject var camera: CameraModel

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) - 6
            ZStack {
                Circle().fill(Color.white.opacity(0.06))
                switch camera.access {
                case .granted:
                    CameraPreview(session: camera.session)
                        .scaleEffect(x: -1, y: 1)   // a mirror
                        .clipShape(Circle())
                case .unknown:
                    label("camera", "Mirror")
                        .onTapGesture { camera.requestAccess() }
                case .denied:
                    label("video.slash", "Allow the camera in System Settings")
                case .none:
                    label("video.slash", "No camera")
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20))
            Text(text).font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
        }
        .foregroundColor(Color.white.opacity(0.75))
        .padding(10)
        .contentShape(Circle())
    }
}

/// The camera's picture (AVFoundation's preview layer).
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// --- Timer ------------------------------------------------------------------------------------

/// Set a time (− and +, or 5, 10, 25 minutes), start, pause, reset. Shows in the closed capsule
/// while it runs; a card and a sound when the time is up.
struct TimerWidget: View {
    @EnvironmentObject var timer: TimerModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                StepButton(symbol: "minus") { timer.step(-1) }
                    .disabled(timer.state == .done)
                Text(TimerModel.text(timer.state == .idle ? timer.duration : timer.remaining))
                    .font(.system(size: 26, weight: .light).monospacedDigit())
                    .foregroundColor(timer.state == .done ? MunaColor.amber : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
                StepButton(symbol: "plus") { timer.step(1) }
            }
            switch timer.state {
            case .idle:
                HStack(spacing: 6) {
                    ForEach(TimerModel.presets, id: \.self) { minutes in
                        Button { timer.set(minutes: minutes) } label: {
                            Text("\(minutes)m")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .frame(height: 22)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                WideButton(symbol: "play.fill", label: "Start", primary: true) { timer.start() }
            case .running:
                HStack(spacing: 6) {
                    WideButton(symbol: "pause.fill", label: "Pause", primary: true) { timer.pause() }
                    WideButton(symbol: "arrow.counterclockwise", label: "Reset") { timer.reset() }
                }
            case .paused:
                HStack(spacing: 6) {
                    WideButton(symbol: "play.fill", label: "Resume", primary: true) { timer.start() }
                    WideButton(symbol: "arrow.counterclockwise", label: "Reset") { timer.reset() }
                }
            case .done:
                Text("Time is up").font(.system(size: 11, weight: .semibold)).foregroundColor(MunaColor.amber)
                HStack(spacing: 6) {
                    WideButton(symbol: "plus", label: "1 min") { timer.step(1) }
                    WideButton(symbol: "checkmark", label: "OK", primary: true) { timer.reset() }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

struct StepButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A full-width round button (Start in white, as on Linux).
struct WideButton: View {
    let symbol: String
    let label: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(primary ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Capsule().fill(primary ? Color.white : Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// --- To-do and notes ----------------------------------------------------------------------------

struct TodoWidget: View {
    @EnvironmentObject var todo: TodoModel
    @EnvironmentObject var ui: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(todo.items.isEmpty ? "To-do" : "To-do · \(todo.openCount)") {
                if todo.hasDone {
                    Pill(label: "Clear done") { todo.clearDone() }
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(todo.items) { item in
                        HStack(spacing: 6) {
                            Button { todo.toggle(item) } label: {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 12))
                                    .foregroundColor(item.done ? MunaColor.ok : Color.white.opacity(0.45))
                            }
                            .buttonStyle(.plain)
                            Text(item.text)
                                .font(.system(size: 11))
                                .strikethrough(item.done)
                                .foregroundColor(item.done ? Color.white.opacity(0.4) : MunaColor.text)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            IconButton(symbol: "xmark") { todo.remove(item) }
                        }
                    }
                }
            }
            CapsuleField(placeholder: "Add a to-do", text: $ui.todoDraft) {
                if todo.add(ui.todoDraft) { ui.todoDraft = "" }
            }
        }
    }
}

struct NotesWidget: View {
    @EnvironmentObject var notes: NotesModel
    @EnvironmentObject var ui: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(notes.notes.isEmpty ? "Notes" : "Notes · \(notes.notes.count)")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(notes.notes) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Text(note.isPrivate ? "Private note" : note.text)
                                .font(.system(size: 11))
                                .foregroundColor(note.isPrivate ? Color.white.opacity(0.4) : MunaColor.text)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            IconButton(symbol: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(note.text, forType: .string)
                            }
                            IconButton(symbol: "xmark") { notes.remove(note) }
                        }
                    }
                }
            }
            CapsuleField(placeholder: "Write a note, Enter saves it", text: $ui.noteDraft) {
                if notes.add(ui.noteDraft) { ui.noteDraft = "" }
            }
        }
    }
}

// --- Shortcuts --------------------------------------------------------------------------------

/// Favourite apps (chosen in the settings); a click starts one.
struct ShortcutsWidget: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var model: CapsuleModel

    var body: some View {
        let apps = preferences.shortcutApps.map { URL(fileURLWithPath: $0) }
        if apps.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.system(size: 22)).foregroundColor(Color.white.opacity(0.3))
                Pill(label: "Choose apps") { model.onSettings() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                ForEach(apps, id: \.self) { app in
                    Button {
                        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                    } label: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .help(app.deletingPathExtension().lastPathComponent)
                }
            }
        }
    }
}
