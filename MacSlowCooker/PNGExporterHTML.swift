import Foundation

/// Pure renderer for the PNG-export landing page. The page lists every panel
/// × granularity image and auto-refreshes once a minute so an open browser
/// always shows the latest snapshot the exporter has written to disk.
enum PNGExporterHTML {
    static func render(
        nowTs: Int,
        panels: [HistoryPanel],
        granularities: [HistoryGranularity]
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(nowTs))
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let stamp = fmt.string(from: date)

        var html = ""
        html += "<!DOCTYPE html>\n"
        html += "<html lang=\"en\">\n"
        html += "<head>\n"
        html += "  <meta charset=\"utf-8\">\n"
        html += "  <meta http-equiv=\"refresh\" content=\"60\">\n"
        html += "  <title>MacSlowCooker — Live Metrics</title>\n"
        html += "  <style>\n"
        html += "    body { font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;\n"
        html += "           background: #f0f0f0; color: #222; max-width: 720px; margin: 24px auto; padding: 0 16px; }\n"
        html += "    h1 { font-size: 18px; margin: 0 0 4px; }\n"
        html += "    h2 { font-size: 14px; margin: 28px 0 8px; padding-bottom: 4px; border-bottom: 1px solid #aaa; }\n"
        html += "    img { display: block; margin: 6px 0 14px; border: 1px solid #888; max-width: 100%; }\n"
        html += "    .stamp { color: #666; font-size: 11px; font-family: ui-monospace, Menlo, monospace; }\n"
        html += "  </style>\n"
        html += "</head>\n"
        html += "<body>\n"
        html += "  <h1>MacSlowCooker — Live Metrics</h1>\n"
        html += "  <p class=\"stamp\">Last updated: \(stamp)</p>\n"
        for panel in panels {
            html += "  <h2>\(panel.title)</h2>\n"
            for g in granularities {
                let filename = "\(panel.id)-\(g.id).png"
                html += "  <img src=\"\(filename)\" alt=\"\(panel.title) \(g.id)\">\n"
            }
        }
        html += "</body>\n"
        html += "</html>\n"
        return html
    }
}
