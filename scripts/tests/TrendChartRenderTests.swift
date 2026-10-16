import AppKit

@main
private struct TrendChartRenderTests {
  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  @MainActor static func main() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let reset = start.addingTimeInterval(1_800)
    let end = start.addingTimeInterval(3_600)
    let samples = [
      TrendSample(date: start, remainingPercent: 20, resetAt: reset),
      TrendSample(date: reset, remainingPercent: 100, resetAt: end.addingTimeInterval(3_600)),
      TrendSample(date: end, remainingPercent: 80)
    ]
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    var failures: [String] = []
    var checks = 0
    for (family, size, axis) in [
      ("small", CGSize(width: 144, height: 144), TrendAxisStyle.endpoints),
      ("medium", CGSize(width: 326, height: 140), TrendAxisStyle.full)
    ] {
      for kind in [QuotaWindowKind.session, .weekly] {
        for dashed in [false, true] {
          let name = "\(family)-\(kind.rawValue)-\(dashed ? "dashed" : "solid")"
          let style = seriesStyle(for: kind)
          let line = TrendSeries(id: name, points: samples, color: Color(red: 0, green: 1, blue: 0),
            lineWidth: style.lineWidth, lineOpacity: style.opacity,
            dashPattern: dashed ? [5, 3] : [], drawPriority: style.drawPriority, state: .current)
          let view = TrendChartPlotView(series: [line], startDate: start, endDate: end, axisStyle: axis)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
          let renderer = ImageRenderer(content: view)
          renderer.scale = 2
          guard let image = renderer.cgImage else { throw Failure(description: "Could not render \(name)") }
          let bitmap = NSBitmapImageRep(cgImage: image)
          guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "Could not encode \(name)")
          }
          try png.write(to: output.appendingPathComponent("trend-\(name).png"))

          // The reset occurs halfway across the plot. Inspect its middle, away
          // from both horizontal runs, to require a visible vertical connection.
          let plotWidth = size.width - (axis == .full ? 17 : 0)
          let centerX = Int(plotWidth)
          let rows = Int(size.height * 0.30 * 2)..<Int(size.height * 0.60 * 2)
          var visibleRows = 0
          for y in rows {
            let visible = ((centerX - 4)...(centerX + 4)).contains { x in
              guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
              return color.greenComponent - max(color.redComponent, color.blueComponent) > 0.5
            }
            if visible { visibleRows += 1 }
          }
          let coverage = Double(visibleRows) / Double(rows.count)
          let minimumCoverage = dashed ? 0.35 : 0.95
          checks += 1
          if coverage < minimumCoverage {
            failures.append("\(name): reset connection covers only \(Int(coverage * 100))% of rows")
          }
        }
      }
    }
    guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\n")) }
    print("Passed \(checks) trend chart reset rendering checks.")
  }
}
