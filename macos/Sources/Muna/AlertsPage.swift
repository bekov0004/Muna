import SwiftUI

/// The Alerts section: what Muna told you lately. (On Linux it shows every app's notifications;
/// macOS keeps those to itself, so here they are Muna's own: sendings, received files, the timer.)
struct AlertsPage: View {
    @EnvironmentObject var alerts: AlertsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(alerts.alerts.isEmpty ? "Alerts" : "Alerts · \(alerts.alerts.count)") {
                if !alerts.alerts.isEmpty {
                    Pill(label: "Clear") { alerts.clear() }
                }
            }
            if alerts.alerts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell").font(.system(size: 22)).foregroundColor(Color.white.opacity(0.28))
                    Text("Nothing new").font(.system(size: 11, weight: .semibold)).foregroundColor(Color.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(alerts.alerts) { alert in
                            HStack(spacing: 10) {
                                Image(systemName: alert.symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(alert.ok ? MunaColor.ok : MunaColor.warning)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(alert.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text(alert.details).font(.system(size: 11)).foregroundColor(MunaColor.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(alert.at.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(MunaColor.secondary)
                                IconButton(symbol: "xmark") { alerts.remove(alert) }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 12).fill(MunaColor.tile))
                        }
                    }
                }
            }
        }
    }
}
